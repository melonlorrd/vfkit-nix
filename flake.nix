{
  description = "vfkit-nix: declarative Debian/Fedora VMs and fleets on macOS (vfkit + cloud-init)";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      pkgs = nixpkgs.legacyPackages.aarch64-darwin;

      # python3Minimal: the full python3 pulls in ~1.4 GiB of Apple SDK + LLVM
      vf = pkgs.writeShellScriptBin "vf" ''
        export VF_SWITCH=${./scripts/vf-switch.py} VF_SELF=${self} PATH=${pkgs.qemu-utils}/bin:$PATH
        exec ${pkgs.python3Minimal}/bin/python3 ${./scripts/vf.py} "$@"
      '';

      mkProject = import ./lib {
        inherit nixpkgs vf;
        builtinBlueprints = lib.mapAttrs'
          (file: _: lib.nameValuePair (lib.removeSuffix ".nix" file) (import ./blueprints/${file}))
          (builtins.readDir ./blueprints);
      };

      template = path: description: { inherit path description; };
    in
    mkProject ./examples // {
      lib = { inherit mkProject; };

      templates = {
        default = self.templates.vm;
        vm = template ./templates/vm "A single Debian VM for development";
        etcd = template ./templates/etcd "3-node etcd cluster";
        k3s = template ./templates/k3s "3-node k3s: 1 server + 2 agents";
        opensearch = template ./templates/opensearch "3-node OpenSearch cluster";
        valkey = template ./templates/valkey "3-node Valkey: 1 primary + 2 replicas";
        plain = template ./templates/plain "A single VM defined in vf.nix, without a flake.nix";
      };
    };
}
