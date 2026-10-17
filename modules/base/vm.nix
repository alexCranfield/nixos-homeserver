# Only for `just vm`: lets ops log in to the local VM (virtual machine) over SSH.
#
# Everything sits under `virtualisation.vmVariant`, which only the VM build
# (`system.build.vm`) reads, so the real host's `system.build.toplevel` is
# unchanged by this file.
#
# Bound to 127.0.0.1: QEMU's default listens on every interface, which on a
# Linux workstation is the LAN and under WSL2 includes the Windows host.
#
# The forwarded connection arrives on the VM's eth0, QEMU's user-mode network.
# The host opens SSH only on its own LAN port (ticket 1.4, #11), which the VM
# does not have, so eth0 gets port 22 and a DHCP (Dynamic Host Configuration
# Protocol) address here. Without them the forward connects to nothing.
{
  virtualisation.vmVariant = {
    virtualisation.forwardPorts = [
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = 2222;
        guest.port = 22;
      }
    ];
    networking.interfaces.eth0.useDHCP = true;
    networking.firewall.interfaces.eth0.allowedTCPPorts = [ 22 ];
  };
}
