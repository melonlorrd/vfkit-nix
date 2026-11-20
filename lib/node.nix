# @VF_USER@ and @VF_SSH_PUBKEY@ are filled in by `vf up`, so the store holds no user-specific data.
{ pkgs, lib, util, images, blueprintOf, node, fleet }:
let
  toYAML = name: value: pkgs.runCommand name { nativeBuildInputs = [ pkgs.yq-go ]; } ''
    yq -P -o=yaml '.' ${pkgs.writeText "${name}.json" (builtins.toJSON value)} > $out
  '';

  special = [ "ready" "artifacts" "notes" ];
  outputs = map
    (b: blueprintOf node b { inherit lib pkgs node fleet; settings = node.settings.${b}; })
    node.blueprints;
  artifacts = lib.foldl' (acc: o: acc // (o.artifacts or { })) { } outputs;
  ready = lib.concatMap (o: lib.toList (o.ready or [ ])) outputs;
  notes = lib.concatStringsSep "\n" (lib.filter (s: s != "") (map (o: o.notes or "") outputs));
  blueprintCloudConfig = lib.foldl' (acc: o: util.mergeCloudConfig acc (removeAttrs o special)) { } outputs;

  hasData = node.data.size > 0;
  addrOf = n: if n.privateIp != null then n.privateIp else n.ip;
  hostsLines = lib.concatMapStrings
    (n: lib.optionalString (addrOf n != null) "${addrOf n} ${n.name}\n")
    fleet.nodes;

  # Formatted only if blank, so it survives a rebuild; grown on every boot.
  dataScript = ''d=/dev/disk/by-id/virtio-vfdata; udevadm settle; [ -b "$d" ] || exit 0; if ! blkid "$d" >/dev/null 2>&1; then mkfs.ext4 -q -L vfdata -E root_owner=1000:1000 "$d"; else resize2fs "$d" >/dev/null 2>&1 || true; fi'';

  base = {
    hostname = node.name;
    manage_etc_hosts = false;
    users = [{
      name = "@VF_USER@";
      shell = "/bin/bash";
      lock_passwd = true;
      sudo = "ALL=(ALL) NOPASSWD:ALL";
      ssh_authorized_keys = [ "@VF_SSH_PUBKEY@" ];
    }];
    ssh_pwauth = false;
    growpart = { mode = "auto"; devices = [ "/" ]; };
    resize_rootfs = true;
    write_files = [{
      path = "/etc/hosts";
      content = ''
        127.0.0.1 localhost
        127.0.1.1 ${node.name}
        ::1 localhost ip6-localhost ip6-loopback
        ${hostsLines}'';
    }];
    mounts =
      map (m: [ m.tag m.target "virtiofs" "defaults,nofail" "0" "0" ]) node.mounts
      ++ lib.optional hasData [ "LABEL=vfdata" node.data.mount "ext4" "defaults,nofail,x-systemd.device-timeout=10s" "0" "2" ]
      ++ lib.mapAttrsToList (k: _: [ "vfa-${k}" "/opt/vf/${k}" "virtiofs" "ro,defaults,nofail" "0" "0" ]) artifacts;
  } // lib.optionalAttrs hasData {
    bootcmd = [ [ "sh" "-c" dataScript ] ];
  };

  userData = util.mergeCloudConfig (util.mergeCloudConfig base blueprintCloudConfig) node.cloudInit;

  gateway = ip: lib.concatStringsSep "." (lib.take 3 (lib.splitString "." ip) ++ [ "1" ]);

  # netplan v2: cloud-init renders it for networkd (Debian) or NetworkManager (Fedora)
  networkConfig = {
    version = 2;
    ethernets = {
      vfnat = { match.macaddress = node.mac; inherit (node) mtu; } // (
        if node.ip != null then {
          addresses = [ "${node.ip}/24" ];
          routes = [{ to = "0.0.0.0/0"; via = gateway node.ip; }];
          nameservers.addresses = [ (gateway node.ip) ];
        } else { dhcp4 = true; }
      );
    } // lib.optionalAttrs (node.privateNetwork != null) {
      vfprivate = {
        match.macaddress = node.privateMac;
        addresses = [ "${node.privateIp}/${toString node.privatePrefix}" ];
      };
    };
  };

  metaData = {
    instance-id = "${node.name}-${builtins.substring 0 12 (builtins.hashString "sha256" (builtins.toJSON [ userData networkConfig ]))}";
    local-hostname = node.name;
  };

  hostPath = s:
    if lib.hasPrefix "/" s then lib.escapeShellArg s
    else if lib.hasPrefix "~/" s then ''"$HOME"/${lib.escapeShellArg (lib.removePrefix "~/" s)}''
    else ''"$P"/${lib.escapeShellArg s}'';
  dev = s: "  --device ${s} \\";
  runScript = pkgs.writeShellScript "run-${node.name}" ''
    # vfkit command for ${node.name}. Usage: run <state-dir> <net-dir> <project-dir>
    D="$1"; N="$2"; P="$3"
    exec ${pkgs.vfkit}/bin/vfkit \
      --cpus ${toString node.cpus} --memory ${toString node.memory} \
      --bootloader "efi,variable-store=$D/efivars,create" \
      --cloud-init "$D/cloud-init/user-data,$D/cloud-init/meta-data,$D/cloud-init/network-config" \
    ${lib.concatStringsSep "\n" (
      [ (dev ''"virtio-blk,path=$D/disk.raw"'')
        (dev ''"virtio-net,nat,mac=${node.mac}"'') ]
      ++ lib.optional (node.privateNetwork != null)
        (dev ''"virtio-net,unixSocketPath=$N/${node.privateNetwork}.sock,mac=${node.privateMac}"'')
      ++ [ (dev "virtio-rng")
           (dev ''"virtio-serial,logFilePath=$D/console.log"'') ]
      ++ lib.optional hasData (dev ''"virtio-blk,path=$D/data.raw,deviceId=vfdata"'')
      ++ map (m: dev ''virtio-fs,sharedDir=${hostPath m.source},mountTag=${m.tag}'') node.mounts
      ++ lib.mapAttrsToList (k: p: dev ''"virtio-fs,sharedDir=${p},mountTag=vfa-${k}"'') artifacts
    )}
      --restful-uri "unix://$D/vfkit.sock"
  '';

  nodeJson = {
    image = "${images.${node.os}}";
    diskGiB = node.disk;
    dataGiB = node.data.size;
    mounts = map (m: m.source) node.mounts;
    inherit ready notes;
  };
in
pkgs.runCommand "vfkit-node-${node.name}" { } ''
  mkdir -p $out/cloud-init $out/bin
  { echo '#cloud-config'; cat ${toYAML "user-data" userData}; } > $out/cloud-init/user-data
  cp ${toYAML "meta-data" metaData} $out/cloud-init/meta-data
  cp ${toYAML "network-config" networkConfig} $out/cloud-init/network-config
  ln -s ${runScript} $out/bin/run
  cp ${pkgs.writeText "node.json" (builtins.toJSON nodeJson)} $out/node.json
''
