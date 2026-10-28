# Unit tests for modules/observability/alert-relay.py. Standard library only.
import importlib.util
import json
import os
import stat
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("alert_relay", os.environ["RELAY"])
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)


def alert(status="firing", **over):
    a = {
        "status": status,
        "labels": {"alertname": "DiskFilling"},
        "annotations": {"summary": "disk 91% full", "description": "/ is filling"},
        "startsAt": "2026-10-28T10:00:00.123456789Z",
        "endsAt": "0001-01-01T00:00:00Z",
    }
    a.update(over)
    return a


class MessagesTest(unittest.TestCase):
    def test_firing_pings(self):
        [(icon, title, body, ping)] = relay.messages({"alerts": [alert()]}, "nuc")
        self.assertEqual(icon, "🔴")
        self.assertEqual(title, "nuc: disk 91% full")
        self.assertEqual(body, "/ is filling")
        self.assertTrue(ping)

    def test_resolved_does_not_ping_and_says_how_long(self):
        a = alert("resolved", endsAt="2026-10-28T11:05:00Z")
        [(icon, title, body, ping)] = relay.messages({"alerts": [a]}, "nuc")
        self.assertEqual(icon, "✅")
        self.assertEqual(title, "nuc: resolved: disk 91% full")
        self.assertIn("/ is filling", body)
        self.assertIn("1 h 5 min", body)
        self.assertFalse(ping)

    def test_two_alerts_two_messages(self):
        b = alert(labels={"alertname": "HostCpuHigh"})
        b["annotations"] = {"summary": "cpu 95%", "description": "busy"}
        msgs = relay.messages({"alerts": [alert(), b]}, "nuc")
        self.assertEqual(len(msgs), 2)
        self.assertEqual(msgs[1][1], "nuc: cpu 95%")

    def test_summary_passed_verbatim(self):
        # The sender neutralises mentions and fences; the relay must not
        # reshape the text, and each message is one argument.
        summary = "@everyone ```x``` $(id) ; rm"
        a = alert(annotations={"summary": summary, "description": "d"})
        with tempfile.TemporaryDirectory() as d:
            sender = os.path.join(d, "sender")
            with open(sender, "w") as f:
                f.write(
                    "#!/bin/sh\n"
                    f'for a in "$@"; do printf "%s\\0" "$a"; done > {d}/args\n'
                    f"cat > {d}/stdin\n"
                )
            os.chmod(sender, stat.S_IRWXU)
            ok = relay.handle({"alerts": [a]}, sender, "/w", "/r", "nuc")
            self.assertTrue(ok)
            with open(f"{d}/args") as f:
                args = f.read().split("\0")[:-1]
            with open(f"{d}/stdin") as f:
                stdin = f.read()
        self.assertEqual(args, ["/w", "/r", "🔴", "nuc: " + summary])
        self.assertEqual(stdin, "d")

    def test_failed_post_returns_500(self):
        with tempfile.TemporaryDirectory() as d:
            sender = os.path.join(d, "sender")
            with open(sender, "w") as f:
                f.write("#!/bin/sh\ncat > /dev/null\nexit 1\n")
            os.chmod(sender, stat.S_IRWXU)
            self.assertFalse(relay.handle({"alerts": [alert()]}, sender, "/w", "/r", "nuc"))
            self.assertEqual(relay.status_for({"alerts": [alert()]}, sender, "/w", "/r", "nuc"), 500)
            missing = os.path.join(d, "nonexistent")
            self.assertFalse(relay.handle({"alerts": [alert()]}, missing, "/w", "/r", "nuc"))

    def test_missing_summary_falls_back_to_alertname(self):
        a = alert(annotations={})
        [(_, title, body, _)] = relay.messages({"alerts": [a]}, "nuc")
        self.assertEqual(title, "nuc: DiskFilling")
        self.assertEqual(body, "")


if __name__ == "__main__":
    unittest.main()
