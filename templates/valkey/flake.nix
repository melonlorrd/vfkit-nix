{
  inputs.vfkit-nix.url = "github:melonlorrd/vfkit-nix";

  outputs = { vfkit-nix, ... }: vfkit-nix.lib.mkProject {
    fleets.valkey = {
      blueprints = [ "valkey" ];
      count = 3;                    # valkey-1 is the primary, the rest replicate from it
      cpus = 1;
      memory = 1024;
      data.size = 5;                # RDB/AOF files live on /data/valkey
      ipStart = "192.168.64.131";
      valkey.maxmemory = "512mb";   # default: half of memory
      valkey.extraConfig = {        # any valkey.conf directive
        maxmemory-policy = "allkeys-lru";
      };
    };
  };
}
