{
  inputs.vfkit-nix.url = "github:melonlorrd/vfkit-nix";

  outputs = { vfkit-nix, ... }: vfkit-nix.lib.mkProject {
    fleets.k3s = {
      blueprints = [ "k3s" ];
      disk = 20;
      ipStart = "192.168.64.111";   # roles take IPs alphabetically: agents .111 .112, server .113
      k3s.token = "change-me";
      roles.server = {
        count = 1;                  # 3 = HA with embedded etcd
        cpus = 2;
        memory = 2048;
        k3s.extraConfig.disable = [ "traefik" ];   # server-only config.yaml keys go here
      };
      roles.agent = { count = 2; cpus = 2; memory = 2048; };
    };
  };
}
