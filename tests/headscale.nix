# The stand-in for Tailscale's own servers, shared by tests/tailscale.nix and
# tests/game-access.nix. Headscale is an open-source implementation of
# Tailscale's control server; here it also runs the relay that carries traffic
# between the two networks. It sits on both, as the internet would.
{ pkgs }:
rec {
  # As in nixpkgs' own headscale test: Tailscale talks to its control server
  # over HTTPS (HTTP over TLS, Transport Layer Security) only, so the
  # stand-in needs a certificate the others trust.
  tlsCert = pkgs.runCommand "headscale-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
      -out cert.pem -keyout key.pem \
      -subj '/CN=headscale' -addext "subjectAltName=DNS:headscale"
    mkdir -p $out
    cp key.pem cert.pem $out
  '';
  trustCert = {
    security.pki.certificateFiles = [ "${tlsCert}/cert.pem" ];
  };

  node = {
    virtualisation.vlans = [
      1
      2
    ];
    services.headscale = {
      enable = true;
      port = 8080;
      settings = {
        server_url = "https://headscale";
        prefixes.v4 = "100.64.0.0/10";
        derp = {
          server = {
            enabled = true;
            region_id = 999;
            stun_listen_addr = "0.0.0.0:3478";
          };
          urls = [ ];
        };
        # Set at runtime with `headscale policy set`; until then every device
        # reaches every other, as under Tailscale's default policy.
        policy.mode = "database";
        # MagicDNS: each device answers to <its hostname>.tailnet.
        dns = {
          magic_dns = true;
          base_domain = "tailnet";
          override_local_dns = false;
        };
      };
    };
    services.nginx = {
      enable = true;
      virtualHosts.headscale = {
        addSSL = true;
        sslCertificate = "${tlsCert}/cert.pem";
        sslCertificateKey = "${tlsCert}/key.pem";
        locations."/" = {
          proxyPass = "http://127.0.0.1:8080";
          proxyWebsockets = true;
        };
      };
    };
    networking.firewall = {
      allowedTCPPorts = [
        80
        443
      ];
      allowedUDPPorts = [ 3478 ];
    };
    environment.systemPackages = [
      pkgs.headscale
      pkgs.nmap
    ];
  };
}
