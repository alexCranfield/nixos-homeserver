# The tenant VMs (virtual machines) on the nuc, ADR (Architecture Decision
# Record) 0013: `tenant-dev`, where the tenant develops over a Tailscale share,
# and `tenant-run`, which runs their scheduled jobs. Their network is declared
# here from ticket 6.7 (#197), the VMs themselves from 6.8 (#198).
{
  imports = [ ../../modules/tenants ];

  # Sizes from ADR 0013: 12 GB of the nuc's 96 GB between them.
  homeserver.tenants.vms = {
    tenant-dev = {
      index = 2;
      vcpu = 4;
      memory = 8 * 1024;
      varSize = 60 * 1024;
    };
    tenant-run = {
      index = 3;
      vcpu = 2;
      memory = 4 * 1024;
      varSize = 30 * 1024;
    };
  };
}
