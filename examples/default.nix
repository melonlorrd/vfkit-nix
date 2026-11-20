{
  vms.dev = {
    memory = 4096;
    data.size = 20;
    mounts = [{ tag = "project"; source = "."; target = "/mnt/project"; }];
    cloudInit.packages = [ "git" "curl" "build-essential" ];
  };

  fleets.etcd = {
    blueprints = [ "etcd" ];
    count = 3;
    cpus = 1;
    memory = 1024;
    disk = 10;
    data.size = 5;
    ipStart = "192.168.64.101";
  };

  fleets.k3s = {
    blueprints = [ "k3s" ];
    ipStart = "192.168.64.111";
    roles.server = { count = 1; memory = 2048; };
    roles.agent = { count = 2; memory = 2048; };
  };

  fleets.opensearch = {
    blueprints = [ "opensearch" ];
    count = 3;
    memory = 2048;
    data.size = 10;
    ipStart = "192.168.64.121";
    opensearch.heap = "1g";
  };

  fleets.valkey = {
    blueprints = [ "valkey" ];
    count = 3;
    cpus = 1;
    memory = 1024;
    data.size = 5;
    ipStart = "192.168.64.131";
  };
}
