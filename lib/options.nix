# Any other attribute is a blueprint settings set (e.g. `opensearch.heap`), checked in topology.nix.
{ lib, ... }:
let
  inherit (lib) mkOption types;

  dataType = types.submodule {
    options = {
      size = mkOption { type = types.ints.unsigned; default = 0; description = "Data disk size in GiB. 0 = no data disk."; };
      mount = mkOption { type = types.str; default = "/data"; description = "Mount point of the data disk in the guest."; };
    };
  };

  mountType = types.submodule {
    options = {
      tag = mkOption { type = types.str; description = "virtiofs tag (unique per VM)."; };
      source = mkOption { type = types.str; description = "Directory on the Mac: absolute, ~/..., or relative to the project folder."; };
      target = mkOption { type = types.str; description = "Mount point in the guest."; };
    };
  };

  # For roles every option defaults to null, meaning "use the fleet's value".
  nodeOptions = nullable:
    let
      opt = type: default: description: mkOption (
        if nullable
        then { type = types.nullOr type; default = null; inherit description; }
        else { inherit type default description; }
      );
    in
    {
      os = opt (types.enum [ "debian" "fedora" ]) "debian" "Guest OS image (see images.nix).";
      cpus = opt types.ints.positive 2 "Virtual CPUs.";
      memory = opt types.ints.positive 2048 "Memory in MiB.";
      disk = opt types.ints.positive 20 "OS disk size in GiB (sparse, grow-only).";
      mtu = opt types.ints.positive 1280 "MTU of the NAT interface. Larger values can stall TLS through macOS NAT.";
      data = opt dataType { } "Persistent data disk; survives `vf <name> rebuild` (not `--data`).";
      mounts = opt (types.listOf mountType) [ ] "virtiofs shares from the Mac.";
      cloudInit = opt (types.attrsOf types.anything) { } "Extra cloud-config merged last (lists are appended, attrsets merged).";
    };

  roleType = types.submodule {
    freeformType = types.attrsOf types.anything;
    options = nodeOptions true // {
      count = mkOption { type = types.ints.positive; default = 1; description = "Number of nodes with this role."; };
    };
  };

  fleetType = types.submodule ({ name, ... }: {
    freeformType = types.attrsOf types.anything;
    options = nodeOptions false // {
      blueprints = mkOption { type = types.listOf types.str; default = [ ]; description = "Blueprints applied to every node, in order."; };
      count = mkOption { type = types.nullOr types.ints.positive; default = null; description = "Node count when the fleet has no roles. Nodes are <fleet>-1..N."; };
      roles = mkOption { type = types.attrsOf roleType; default = { }; description = "Node groups. Nodes are <fleet>-<role>-1..N."; };
      ipStart = mkOption { type = types.nullOr types.str; default = null; description = "Static NAT IP of the first node; the rest follow (roles in alphabetical order). null = DHCP."; };
      private = {
        enable = mkOption { type = types.nullOr types.bool; default = null; description = "Private VM-to-VM network. Default: on when the fleet has more than one node."; };
        network = mkOption { type = types.str; default = name; description = "Switch name. Fleets with the same name share a network."; };
        ipStart = mkOption { type = types.str; default = "10.100.0.11"; description = "Private IP of the first node; the rest follow."; };
        prefix = mkOption { type = types.ints.between 8 30; default = 24; description = "Private network prefix length."; };
      };
    };
  });

  vmType = types.submodule {
    freeformType = types.attrsOf types.anything;
    options = nodeOptions false // {
      blueprints = mkOption { type = types.listOf types.str; default = [ ]; description = "Blueprints applied to this VM, in order."; };
      ip = mkOption { type = types.nullOr types.str; default = null; description = "Static NAT IP. null = DHCP."; };
      private = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            network = mkOption { type = types.str; description = "Switch name, shared with fleets/VMs using the same name."; };
            ip = mkOption { type = types.str; description = "This VM's private IP."; };
            prefix = mkOption { type = types.ints.between 8 30; default = 24; description = "Private network prefix length."; };
          };
        });
        default = null;
        description = "Attach to a private network (shared with other VMs/fleets using the same name).";
      };
    };
  };
in
{
  options = {
    vms = mkOption { type = types.attrsOf vmType; default = { }; description = "Single VMs. The attribute name is the VM name."; };
    fleets = mkOption { type = types.attrsOf fleetType; default = { }; description = "Groups of nodes built from blueprints."; };
    blueprints = mkOption { type = types.attrsOf types.raw; default = { }; description = "Project blueprints, merged over the built-in ones (same name replaces)."; };
  };
}
