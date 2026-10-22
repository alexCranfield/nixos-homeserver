# DO NOT MERGE. Rollback drill for ticket 2.4 (#19): a boot-breaking change.
# A filesystem whose device does not exist. Without `nofail`, local-fs.target
# fails at boot and the machine stops in emergency mode. The question is
# whether CI (continuous integration) notices.
{
  fileSystems."/drill" = {
    device = "/dev/disk/by-label/does-not-exist";
    fsType = "ext4";
  };
}
