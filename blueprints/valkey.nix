{
  settings = {
    maxmemory = null;
    extraConfig = { };
  };

  config = { lib, pkgs, node, fleet, settings }:
    let
      primary = builtins.head fleet.nodes;
      isPrimary = node.name == primary.name;
      addr = n: if n.privateIp != null then n.privateIp else n.ip;
      service = if node.os == "fedora" then "valkey" else "valkey-server";
      dataDir = if node.data.size > 0 then "${node.data.mount}/valkey" else "/var/lib/valkey";

      conf = {
        bind = "0.0.0.0";
        protected-mode = "no";
        dir = dataDir;
        appendonly = "yes";
        maxmemory = if settings.maxmemory != null then settings.maxmemory else "${toString (node.memory / 2)}mb";
      } // lib.optionalAttrs (!isPrimary) {
        replicaof = "${addr primary} 6379";
      } // settings.extraConfig;
    in
    assert lib.assertMsg (settings.maxmemory == null || builtins.isString settings.maxmemory)
      "valkey: maxmemory must be a string such as \"512mb\"";
    assert lib.assertMsg (builtins.length fleet.nodes == 1 || lib.all (n: addr n != null) fleet.nodes)
      "valkey: multi-node fleet '${fleet.name}' needs the private network or static IPs";
    {
      packages = [ service ];

      write_files = [
        {
          path = "/etc/valkey/vf.conf";
          content = lib.concatStrings (lib.mapAttrsToList (k: v: "${k} ${toString v}\n") conf);
        }
        {
          path = "/etc/systemd/system/${service}.service.d/vf.conf";
          content = ''
            [Service]
            ReadWritePaths=${dataDir}
          '';
        }
      ];

      runcmd = [
        "mkdir -p ${dataDir} && chown valkey:valkey ${dataDir} && chmod 750 ${dataDir}"
        "grep -q '^include /etc/valkey/vf.conf' /etc/valkey/valkey.conf || echo 'include /etc/valkey/vf.conf' >> /etc/valkey/valkey.conf"
        "systemctl daemon-reload"
        "systemctl enable ${service}"
        "systemctl restart ${service}"
      ];

      ready =
        if isPrimary then "valkey-cli ping | grep -q PONG"
        else "valkey-cli info replication | grep -q master_link_status:up";

      notes = lib.optionalString isPrimary ''
        Valkey '${fleet.name}': primary ${node.name}, ${toString (builtins.length fleet.nodes - 1)} replica(s)
          vf ${node.name} ssh -- valkey-cli info replication
          valkey-cli -h ${if node.ip != null then node.ip else "$(vf ${node.name} ip)"}'';
    };
}
