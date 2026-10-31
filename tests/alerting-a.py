# Half a of tests/alerting.nix: subtests 4, 1, 6, 7 and 8, then 9 and 10,
# which both halves run. The helpers are in alerting.py, before this.
# The numbers are those of the test before it was split (#182), kept so that
# the history and the runbooks still name the same subtest.

with subtest("4. a dead gateway posts, and holds back DnsFailing and TailnetDisconnected"):
    # First: these three fire from boot, and the inhibition must already
    # hold when the two it targets fire.
    nuc.fail(f"ping -c 1 -W 2 {GATEWAY}")
    gw = "The LAN gateway does not answer ping (for 15s)"
    dns = "DNS lookups through the nuc's resolver fail (for 60s)"
    tailnet = "The nuc is not connected to the tailnet (for 60s)"
    check_fired(gw)
    # Firing, and held back: the alerts reached Alertmanager, so the missing
    # posts below are the inhibition's doing.
    for name in ("DnsFailing", "TailnetDisconnected"):
        state = wait_am(name, lambda s: s is not None and s["inhibitedBy"], timeout=600)
        assert state["state"] == "suppressed", state
    # A flush of their groups has passed: they reached Alertmanager above.
    time.sleep(GROUP_WAIT + SLACK)
    assert matching(firing(dns)) == [], received()
    assert matching(firing(tailnet)) == [], received()

    # The gateway answers: its alert resolves, and the two it held back are
    # posted on their own, at their groups' next flush.
    n = len(received())
    nuc.succeed(f"ip addr add {GATEWAY}/32 dev lo")
    nuc.succeed(f"ping -c 1 -W 2 {GATEWAY}")
    check_resolved(gw, n)
    check_fired(tailnet, n)
    check_fired(dns, n)

    # Tailscale's state as a logged-in node reports it, held still: the
    # timer would write 0 again.
    n = len(received())
    nuc.succeed("systemctl stop tailscale-state.timer tailscale-state.service")
    nuc.succeed(
        f"printf 'homeserver_tailscale_running 1\\nhomeserver_tailscale_health_messages 0\\n' > {TEXTFILE}.tmp"
        f" && mv {TEXTFILE}.tmp {TEXTFILE}"
    )
    check_resolved(tailnet, n)
    # DnsFailing stays firing: this VM has no DNS upstream. It never posts
    # again (repeat_interval 12 h), so the counts below are not disturbed.

with subtest("1. TargetDown: a stopped node-exporter posts once, then resolves"):
    target = "Scrape target node is down (for 30s)"
    n = len(received())
    start = time.monotonic()
    nuc.succeed("systemctl stop prometheus-node-exporter.service")
    check_fired(target, n)
    print(f"TargetDown: {time.monotonic() - start:.0f} s from stop to post")
    nuc.succeed("systemctl start prometheus-node-exporter.service")
    check_resolved(target, n)
    assert len(matching(firing(target), n)) == 1, received()[n:]

with subtest("6. two alerts firing, one resolving: the other is not posted again"):
    amtool = f"amtool --alertmanager.url={AM}"
    # GapControl (tests/alerting.nix) is UnitFailed without keep_firing_for,
    # the negative control for the scrape gap below. Silenced throughout, so
    # it never posts.
    nuc.succeed(
        f"{amtool} silence add alertname=GapControl --duration 2h"
        " --author test --comment 'negative control'"
    )
    n = len(received())
    nuc.succeed("systemd-run --unit fail-a false")
    nuc.succeed("systemd-run --unit fail-b false")
    check_fired(unit_failed("fail-a"), n)
    check_fired(unit_failed("fail-b"), n)
    nuc.succeed("systemctl reset-failed fail-a.service")
    check_resolved(unit_failed("fail-a"), n)

    # A missed scrape of node-exporter, as a deploy that restarts it can
    # cause: fail-b's series goes stale, and its alert must ride that out
    # (keep_firing_for in rules.nix) rather than resolve and post again.
    # TargetDown is silenced meanwhile: the gap itself is not what this
    # checks, and it may last past TargetDown's 30 s.
    gap_silence = nuc.succeed(
        f"{amtool} silence add alertname=TargetDown --duration 10m"
        " --author test --comment 'scrape gap'"
    ).strip()
    held_since = wait_active_at("UnitFailed", "fail-b.service")
    control_since = wait_active_at("GapControl", "fail-b.service")
    print("before the gap:", held_since, control_since)
    nuc.succeed("systemctl stop prometheus-node-exporter.service")
    deadline = time.monotonic() + 120
    gap_start = time.monotonic()
    while not prom('up{job="node"} == 0'):
        assert time.monotonic() < deadline, "no failed scrape of node-exporter"
        time.sleep(1)
    # The control has gone with the series: the gap is long enough to drop
    # an alert that does not ride it out.
    deadline = time.monotonic() + 120
    while active_at("GapControl", "fail-b.service") is not None:
        assert time.monotonic() < deadline, "GapControl survived the gap"
        time.sleep(1)
    nuc.succeed("systemctl start prometheus-node-exporter.service")
    deadline = time.monotonic() + 120
    while not prom('up{job="node"} == 1'):
        assert time.monotonic() < deadline, "node-exporter not scraped again"
        time.sleep(1)
    # Roughly how long the series was missing: from the stop to the first
    # good scrape the script saw. Printed to compare with the grace, after
    # which the alert would have resolved.
    print(f"gap: {time.monotonic() - gap_start:.0f} s at most; grace {GRACE} s")
    # The control fires again as a new alert; UnitFailed is the same alert
    # it was before the gap, never resolved.
    control_after = wait_active_at("GapControl", "fail-b.service")
    held_after = active_at("UnitFailed", "fail-b.service")
    print("after the gap:", held_after, control_after)
    assert control_after != control_since, (control_since, control_after)
    assert held_after == held_since, (held_since, held_after)

    # Two more group intervals for a re-post to show up: a resolve, then the
    # alert again.
    time.sleep(2 * GROUP_INTERVAL + SLACK)
    wait_am("TargetDown", lambda s: s is None)
    nuc.succeed(f"{amtool} silence expire {gap_silence}")
    assert len(matching(firing(unit_failed("fail-b")), n)) == 1, received()[n:]
    assert len(received()) == n + 3, received()[n:]
    nuc.succeed("systemctl reset-failed fail-b.service")
    check_resolved(unit_failed("fail-b"), n)
    assert len(received()) == n + 4, received()[n:]

with subtest("7. a silence stops the post"):
    amtool = f"amtool --alertmanager.url={AM}"
    silence = nuc.succeed(
        f"{amtool} silence add alertname=TargetDown --duration 10m"
        " --author test --comment 'alerting test'"
    ).strip()
    print("silence", silence)
    n = len(received())
    nuc.succeed("systemctl stop prometheus-node-exporter.service")
    # The alert fires, and is silenced: so the missing post is the silence's
    # doing, not a quiet rule.
    state = wait_am("TargetDown", lambda s: s is not None and s["silencedBy"])
    assert state["state"] == "suppressed", state
    # It reached Alertmanager, so its group's first flush is due within
    # group_wait.
    time.sleep(GROUP_WAIT + SLACK)
    assert received()[n:] == [], received()[n:]
    nuc.succeed("systemctl start prometheus-node-exporter.service")
    wait_am("TargetDown", lambda s: s is None)
    nuc.succeed(f"{amtool} silence expire {silence}")
    # Resolved while silenced, never posted: nothing to say it resolved, at
    # the group's next flush.
    time.sleep(GROUP_INTERVAL + SLACK)
    assert received()[n:] == [], received()[n:]

with subtest("8. a post that fails while Discord is down arrives once it is back"):
    n = len(received())
    nuc.succeed("systemctl stop webhook-receiver.service")
    nuc.succeed("systemd-run --unit fail-outage false")
    # The relay tried, and failed (the alert takes up to a scrape, an
    # evaluation and group_wait to get there). No fixed sleep first: the
    # receiver should be back as early as it can, inside the notification
    # that failed.
    nuc.wait_until_succeeds(
        "journalctl -u alert-relay -o cat --no-pager | grep -F 'post of UnitFailed failed'",
        timeout=180,
    )
    nuc.succeed("systemctl start webhook-receiver.service")
    check_fired(unit_failed("fail-outage"), n)
    # Once: no retry of a post that went through, which would come at the
    # group's next flush.
    time.sleep(GROUP_INTERVAL + SLACK)
    assert len(received()) == n + 1, received()[n:]
    nuc.succeed("systemctl reset-failed fail-outage.service")
    check_resolved(unit_failed("fail-outage"), n)

with subtest("9. Alertmanager, the relay and the blackbox exporter listen on loopback only"):
    loopback_only()

with subtest("10. the webhook URL is not in the journal"):
    webhook_not_in_journal()
