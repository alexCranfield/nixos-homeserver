# Host-agnostic system defaults: clock, locale, bootloader retention, admin tools.
{ ... }:
{
  # UTC, so logs never jump at daylight-saving changes and timers mean the same
  # thing all year. Maintenance windows are written in UTC.
  time.timeZone = "UTC";
  # The NixOS default, stated so it is a decision rather than an accident.
  i18n.defaultLocale = "en_US.UTF-8";

  # Ten generations in the boot menu: enough to roll back past a bad week of
  # deploys without filling the ESP (EFI System Partition).
  boot.loader.systemd-boot.configurationLimit = 10;

  programs.git.enable = true;
  # Defaults for now. Porting the tmux configuration from the previous project
  # is left to Alex, with home-manager in ticket 6.1 (#39).
  programs.tmux.enable = true;
}
