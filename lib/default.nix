{ nixpkgs, vf, builtinBlueprints }:
project:
let
  system = "aarch64-darwin";
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;
  util = import ./util.nix { inherit lib; };
  images = import ../images.nix { inherit pkgs; };

  cfg = (lib.evalModules { modules = [ ./options.nix project ]; }).config;
  topo = import ./topology.nix {
    inherit lib cfg util;
    blueprints = builtinBlueprints // cfg.blueprints;
  };

  nodes = lib.mapAttrs
    (_: node: import ./node.nix {
      inherit pkgs lib util images node;
      inherit (topo) blueprintOf;
      fleet = topo.fleets.${node.fleet};
    })
    topo.nodes;

  vfInfo = {
    nodes = lib.mapAttrs (_: n: builtins.deepSeq n.settings { inherit (n) os cpus memory ip privateIp privateNetwork mac; }) topo.nodes;
    fleets = lib.mapAttrs (_: f: map (n: n.name) f.nodes) topo.fleets;
  };
in
{
  packages.${system} = { default = vf; inherit vf; };
  legacyPackages.${system} = { inherit nodes vfInfo; };
  devShells.${system}.default = pkgs.mkShell {
    packages = [ vf ];
    shellHook = ''export VF_FLAKE="$PWD"'';
  };
}
