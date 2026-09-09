# The nuc host: an ASRock Industrial NUC BOX-358H.
{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/base
  ];

  nixpkgs.hostPlatform = "x86_64-linux";
}
