# The tenant VMs (virtual machines) on the nuc, ADR (Architecture Decision
# Record) 0013: `tenant-dev`, where the tenant develops over a Tailscale share,
# and `tenant-run`, which runs their scheduled jobs. Their network is declared
# here from ticket 6.7 (#197); the VMs themselves arrive in 6.8 (#198).
{
  imports = [ ../../modules/tenants ];

  homeserver.tenants.vms = {
    tenant-dev.index = 2;
    tenant-run.index = 3;
  };
}
