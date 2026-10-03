# Only for `just vm`: lets ops log in to the local VM (virtual machine) over SSH.
#
# Everything sits under `virtualisation.vmVariant`, which only the VM build
# (`system.build.vm`) reads, so the real host's `system.build.toplevel` is
# unchanged by this file.
#
# Bound to 127.0.0.1: QEMU's default listens on every interface, which would
# put the VM's sshd on the workstation's LAN.
{
  virtualisation.vmVariant.virtualisation.forwardPorts = [
    {
      from = "host";
      host.address = "127.0.0.1";
      host.port = 2222;
      guest.port = 22;
    }
  ];
}
