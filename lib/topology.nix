{ lib, cfg, util, blueprints }:
let
  nodeKeys = [ "os" "cpus" "memory" "disk" "mtu" "data" "mounts" "cloudInit" ];
  structural = nodeKeys ++ [ "blueprints" "count" "roles" "ipStart" "private" "ip" "_module" ];
  userSettings = c: removeAttrs c structural;

  blueprintNamed = where: b:
    blueprints.${b} or (throw "vfkit-nix: ${where}: unknown blueprint '${b}' (available: ${toString (builtins.attrNames blueprints)})");

  checkSetting = where: b: defaults: k: v:
    if !(defaults ? ${k}) then
      throw "vfkit-nix: ${where}: unknown setting '${b}.${k}' (valid: ${toString (builtins.attrNames defaults)})"
    else if defaults.${k} != null && builtins.typeOf v != builtins.typeOf defaults.${k} then
      throw "vfkit-nix: ${where}: '${b}.${k}' must be of type ${builtins.typeOf defaults.${k}}, got ${builtins.typeOf v}"
    else v;

  # Blueprint settings: defaults from the blueprint, overridden by the fleet, then by the role.
  resolveSettings = where: bps: given:
    let unknown = lib.subtractLists bps (builtins.attrNames given); in
    if unknown != [ ] then
      throw "vfkit-nix: ${where}: unknown option '${builtins.head unknown}' (node options: ${toString nodeKeys}${lib.optionalString (bps != [ ]) "; blueprint settings: ${toString bps}"})"
    else
      lib.genAttrs bps (b:
        let
          defaults = (blueprintNamed where b).settings or { };
          g = given.${b} or { };
        in
        if !builtins.isAttrs g then throw "vfkit-nix: ${where}: '${b}' must be an attribute set of settings"
        else defaults // lib.mapAttrs (checkSetting where b defaults) g);

  pick = role: fleet: k: if (role.${k} or null) != null then role.${k} else fleet.${k};

  expandFleet = fname: f:
    let
      plain = f.roles == { };
      roleNames = if plain then [ "node" ] else lib.sort lib.lessThan (builtins.attrNames f.roles);
      roleCfg = r: if plain then { count = if f.count == null then 1 else f.count; } else f.roles.${r};
      entries = lib.concatMap (r: lib.genList (i: { role = r; index = i + 1; }) (roleCfg r).count) roleNames;
      privateOn = if f.private.enable != null then f.private.enable else builtins.length entries > 1;
    in
    lib.imap0
      (k: e:
        let
          rc = roleCfg e.role;
          name = if plain then "${fname}-${toString e.index}" else "${fname}-${e.role}-${toString e.index}";
        in
        {
          inherit name;
          fleet = fname;
          inherit (e) role index;
          fleetIndex = k + 1;
          cloudInit = util.mergeCloudConfig f.cloudInit (if (rc.cloudInit or null) == null then { } else rc.cloudInit);
          ip = if f.ipStart == null then null else util.ipAdd f.ipStart k;
          privateNetwork = if privateOn then f.private.network else null;
          privateIp = if privateOn then util.ipAdd f.private.ipStart k else null;
          privatePrefix = f.private.prefix;
          mac = util.macFor name;
          privateMac = util.macFor "${name}-private";
          inherit (f) blueprints;
          settings = resolveSettings name f.blueprints
            (lib.recursiveUpdate (userSettings f) (if plain then { } else userSettings rc));
        } // lib.genAttrs (lib.remove "cloudInit" nodeKeys) (pick rc f))
      entries;

  vmNode = name: v: {
    inherit name;
    fleet = name;
    role = "vm";
    index = 1;
    fleetIndex = 1;
    inherit (v) os cpus memory disk mtu data mounts cloudInit ip blueprints;
    privateNetwork = if v.private == null then null else v.private.network;
    privateIp = if v.private == null then null else v.private.ip;
    privatePrefix = if v.private == null then 24 else v.private.prefix;
    mac = util.macFor name;
    privateMac = util.macFor "${name}-private";
    settings = resolveSettings name v.blueprints (userSettings v);
  };

  fleetNodes = lib.mapAttrs expandFleet cfg.fleets // lib.mapAttrs (n: v: [ (vmNode n v) ]) cfg.vms;
  allNodes = lib.concatLists (builtins.attrValues fleetNodes);
  names = map (n: n.name) allNodes;
in
assert lib.assertMsg (lib.length names == lib.length (lib.unique names))
  "vfkit-nix: node names must be unique, got duplicates in: ${toString names}";
assert lib.assertMsg (lib.all (f: !(cfg.vms ? ${f})) (builtins.attrNames cfg.fleets))
  "vfkit-nix: a VM and a fleet can't share a name";
{
  nodes = lib.listToAttrs (map (n: lib.nameValuePair n.name n) allNodes);
  fleets = lib.mapAttrs (name: nodes: { inherit name nodes; }) fleetNodes;
  blueprintOf = node: b: (blueprintNamed node.name b).config;
}
