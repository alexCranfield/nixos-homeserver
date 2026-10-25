# The `hello` stack: see compose.yml. Each stack under stacks/ declares itself
# like this, and hosts/nuc imports the ones it runs (docs/runbooks/stacks.md).
{
  homeserver.stacks.hello = {
    composeFile = ./compose.yml;
    services = [ "web" ];
    # Nothing is mounted: hello is where a rollback is practised
    # (docs/runbooks/data-layout.md).
    dataDir = "/srv/data/hello";
    uid = 40000;
    gid = 40000;
    resources.memoryMax = "64M";
  };
}
