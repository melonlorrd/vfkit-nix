{
  vms.dev = {
    os = "debian";
    cpus = 2;
    memory = 4096;
    data.size = 20;
    cloudInit.packages = [ "git" "curl" ];
  };
}
