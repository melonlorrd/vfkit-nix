{
  inputs.vfkit-nix.url = "github:melonlorrd/vfkit-nix";

  outputs = { vfkit-nix, ... }: vfkit-nix.lib.mkProject {
    fleets.opensearch = {
      blueprints = [ "opensearch" ];
      count = 3;                    # every node is cluster_manager + data + ingest
      cpus = 2;
      memory = 2048;
      disk = 20;
      data.size = 10;               # indices live on /data/opensearch
      ipStart = "192.168.64.121";
      opensearch.heap = "1g";       # default: half of memory
      opensearch.extraConfig = {    # any opensearch.yml key
        "cluster.routing.allocation.disk.threshold_enabled" = false;
      };
    };
  };
}
