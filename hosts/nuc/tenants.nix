# The tenant VMs (virtual machines) on the nuc, ADR (Architecture Decision
# Record) 0013: `tenant-dev`, where the tenant develops over a Tailscale share,
# and `tenant-run`, which runs their scheduled jobs. Their network is declared
# here from ticket 6.7 (#197), the VMs themselves from 6.8 (#198), the
# runner from 6.9 (#199), the dev VM's own side from 6.10 (#200).
{
  imports = [ ../../modules/tenants ];

  # Sizes from ADR 0013: 12 GB of the nuc's 96 GB between them.
  homeserver.tenants.vms = {
    tenant-dev = {
      index = 2;
      vcpu = 4;
      memory = 8 * 1024;
      varSize = 60 * 1024;
      # The tenant SSHes in over a Tailscale share (6.10, #200), with the
      # secrets `dev_ssh_key` and `dev_tailscale_auth_key` in
      # secrets/tenant.yaml.
      dev = true;
    };
    tenant-run = {
      index = 3;
      vcpu = 2;
      memory = 4 * 1024;
      varSize = 30 * 1024;
      # Deploys the tenant's private repo, whose URL is the sops secret
      # `repo_url` in secrets/tenant.yaml (6.9, #199).
      runner = true;
    };
  };
}
