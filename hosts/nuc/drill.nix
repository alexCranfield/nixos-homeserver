# Rollback drill for ticket 2.4 (#19): a broken service, merged on purpose and
# then reverted. It fails every time it starts, so comin's switch reports the
# deployment failed and both failures post to Discord (#20), while the rest of
# the host, SSH above all, keeps running. Revert the merge to recover.
{
  homeserver.notify.units = [ "drill-broken" ];
  systemd.services.drill-broken = {
    description = "Rollback drill: a service that always fails (#19)";
    wantedBy = [ "multi-user.target" ];
    # On the nuc only. In a test VM (virtual machine) systemd skips it, which
    # is not a failure, so CI (continuous integration) stays green and the
    # drill can merge; tests/notify.py would otherwise see an extra message.
    unitConfig.ConditionVirtualization = "no";
    serviceConfig.Type = "oneshot";
    script = ''
      echo "drill #19: failing on purpose"
      exit 1
    '';
  };
}
