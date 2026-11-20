{
  inputs.vfkit-nix.url = "github:melonlorrd/vfkit-nix";

  outputs = { vfkit-nix, ... }: vfkit-nix.lib.mkProject {
    fleets.etcd = {
      blueprints = [ "etcd" ];
      count = 3;                    # etcd-1 .. etcd-3
      cpus = 1;
      memory = 1024;
      disk = 10;
      data.size = 5;                # etcd data lives on /data/etcd
      ipStart = "192.168.64.101";   # etcd-1 = .101, etcd-2 = .102, ...
      etcd.extraConfig = {          # any etcd config-file key
        auto-compaction-mode = "periodic";
        auto-compaction-retention = "1h";
      };
    };
  };
}
