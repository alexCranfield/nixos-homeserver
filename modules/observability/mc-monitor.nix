# mc-monitor, itzg's Minecraft status checker (the author of the server's
# image), for minecraft-status in probes.nix (#168). nixpkgs has it from
# 26.11 (version 1.18.2, same hashes); nixos-26.05, which ADR (Architecture
# Decision Record) 0007 pins, does not. Delete this file and use
# `pkgs.mc-monitor` once the pin reaches a release that carries it.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule (finalAttrs: {
  pname = "mc-monitor";
  version = "1.18.2";

  src = fetchFromGitHub {
    owner = "itzg";
    repo = "mc-monitor";
    tag = finalAttrs.version;
    hash = "sha256-juHtv/6IAueimFul0LdhrWUnomfhhWmiMp2gK0/MfT8=";
  };

  vendorHash = "sha256-kbhQVMu7RZ5R2prQ5yVeIFA/QXl/vRwRdWGNlHkUg3A=";

  # Upstream's tests need network access.
  doCheck = false;

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${finalAttrs.version}"
  ];

  meta = {
    description = "Monitor status of Minecraft servers";
    homepage = "https://github.com/itzg/mc-monitor";
    license = lib.licenses.mit;
    mainProgram = "mc-monitor";
  };
})
