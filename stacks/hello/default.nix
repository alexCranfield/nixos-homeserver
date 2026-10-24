# The `hello` stack: see compose.yml. Each stack under stacks/ declares itself
# like this, and hosts/nuc imports the ones it runs (docs/runbooks/stacks.md).
{
  homeserver.stacks.hello = {
    composeFile = ./compose.yml;
    services = [ "web" ];
    resources.memoryMax = "64M";
  };
}
