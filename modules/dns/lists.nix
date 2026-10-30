# The blocklists, by group, ticket #164: the six the Pi-hole used, so the
# cutover blocks the same names (docs/superpowers/specs/2026-10-29-lan-dns-design.md,
# "Blocking"). The group names are what the query log and the alerts show.
#
# Blocky reads hosts files, plain domain lists, `*.` wildcards and regexes.
# Two of the Pi-hole's lists are in adblock syntax (`||name^`), which Blocky
# 0.29 half-reads: it strips the markers and blocks the name alone, not its
# subdomains as the syntax means, and fails a list outright on rules with
# modifiers. Those two are replaced below by the same list in a format Blocky
# reads in full, from the same project. Checked by loading each list into
# Blocky 0.29 on 2026-10-30.
{
  # Hits are normal and only counted.
  ads = [
    # StevenBlack's unified hosts. Hosts format.
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
    # EasyList, as converted by firebog.net. One domain per line.
    "https://v.firebog.net/hosts/Easylist.txt"
    # EasyPrivacy, as converted by firebog.net. One domain per line.
    "https://v.firebog.net/hosts/Easyprivacy.txt"
    # WindowsSpyBlocker's telemetry list. Hosts format.
    "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt"
  ];

  # A hit means a device tried to reach a known malware, phishing or
  # command-and-control domain.
  threats = [
    # HaGeZi's Threat Intelligence Feeds, in its wildcard format (`*.name`),
    # which blocks each name and its subdomains as the Pi-hole's adblock copy
    # (adblock/tif.txt) did. From the same jsDelivr mirror. Its
    # wildcard/tif-onlydomains.txt, the same names without `*.`, would block
    # the names alone in Blocky.
    "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/tif.txt"
    # DandelionSprout's anti-malware list, hosts version. The Pi-hole's copy
    # was AntiMalwareAdGuardHome.txt, adblock syntax with modifiers, of which
    # Blocky loads nothing. Four of this file's lines are IPv6 addresses
    # Blocky can't parse; see `maxErrorsPerSource` in ./default.nix.
    "https://raw.githubusercontent.com/DandelionSprout/adfilt/refs/heads/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareHosts.txt"
  ];
}
