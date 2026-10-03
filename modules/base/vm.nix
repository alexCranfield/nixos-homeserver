# Only for `just vm`: lets ops log in to the local VM (virtual machine) over SSH.
#
# Everything sits under `virtualisation.vmVariant`, which only the VM build
# (`system.build.vm`) reads, so the real host's `system.build.toplevel` is
# unchanged by this file.
#
# Bound to 127.0.0.1: QEMU's default listens on every interface, which on a
# Linux workstation is the LAN and under WSL2 includes the Windows host.
#
# This relies on the VM's firewall allowing port 22 on eth0, QEMU's user-mode
# network. If ticket 1.4 (#11) limits SSH to the Tailscale interface, open 22
# on eth0 here under `vmVariant`, or the forward connects to nothing.
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
