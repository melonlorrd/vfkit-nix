{
  inputs.vfkit-nix.url = "github:melonlorrd/vfkit-nix";

  outputs = { vfkit-nix, ... }: vfkit-nix.lib.mkProject {
    vms.dev = {
      os = "debian";        # "debian" (13) or "fedora" (44)
      cpus = 2;
      memory = 4096;        # MiB
      disk = 20;            # GiB, recreated by `vf dev rebuild`
      data.size = 20;       # GiB at /data, kept across `vf dev rebuild`
      ip = null;            # static NAT IP such as "192.168.64.50"; null = DHCP
      mounts = [            # source: relative to this folder, ~/..., or absolute
        { tag = "project"; source = "."; target = "/mnt/project"; }
      ];
      cloudInit.packages = [ "git" "curl" "build-essential" ];
    };
  };
}
