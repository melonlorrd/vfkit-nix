{
  settings = {
    version = "3.9.0";
    hash = "sha256-13/UlL9bJoVEQRNn9LLZckvSBcVLNt/QGjSO172QklQ=";
    nodeRoles = [ "cluster_manager" "data" "ingest" ];
    heap = null;
    extraConfig = { };
  };

  config = { lib, pkgs, node, fleet, settings }:
    let
      rolesOf = n: n.settings.opensearch.nodeRoles;
      addr = n: if n.privateIp != null then n.privateIp else n.ip;
      managers = lib.filter (n: lib.elem "cluster_manager" (rolesOf n)) fleet.nodes;
      single = builtins.length fleet.nodes == 1;

      heap = if settings.heap != null then settings.heap else "${toString (node.memory / 2)}m";
      dataDir = if node.data.size > 0 then "${node.data.mount}/opensearch" else "/var/lib/opensearch";

      config = {
        "cluster.name" = fleet.name;
        "node.name" = node.name;
        "node.roles" = settings.nodeRoles;
        "path.data" = dataDir;
        "path.logs" = "/var/log/opensearch";
        "network.bind_host" = "0.0.0.0";
        "plugins.security.disabled" = true;
      } // (if single then {
        "discovery.type" = "single-node";
        "network.publish_host" = "127.0.0.1";
      } else {
        "network.publish_host" = addr node;
        "discovery.seed_hosts" = map addr managers;
        "cluster.initial_cluster_manager_nodes" = map (n: n.name) managers;
      }) // settings.extraConfig;
    in
    assert lib.assertMsg (single || lib.all (n: addr n != null) fleet.nodes)
      "opensearch: multi-node fleet '${fleet.name}' needs the private network or static IPs";
    assert lib.assertMsg (settings.heap == null || builtins.isString settings.heap)
      "opensearch: heap must be a string such as \"1g\" or \"768m\"";
    assert lib.assertMsg (managers != [ ]) "opensearch: fleet '${fleet.name}' has no cluster_manager node";
    {
      artifacts.opensearch = pkgs.fetchzip {
        url = "https://artifacts.opensearch.org/releases/bundle/opensearch/${settings.version}/opensearch-${settings.version}-linux-arm64.tar.gz";
        inherit (settings) hash;
      };

      write_files = [
        { path = "/etc/sysctl.d/90-opensearch.conf"; content = "vm.max_map_count = 262144\n"; }
        { path = "/usr/local/lib/vf/opensearch.yml"; content = builtins.toJSON config + "\n"; }
        {
          path = "/etc/systemd/system/opensearch.service";
          content = ''
            [Unit]
            Description=OpenSearch
            After=network-online.target
            Wants=network-online.target
            RequiresMountsFor=/opt/vf/opensearch

            [Service]
            User=opensearch
            WorkingDirectory=/var/lib/opensearch-run
            Environment=OPENSEARCH_HOME=/opt/vf/opensearch
            Environment=OPENSEARCH_PATH_CONF=/etc/opensearch
            Environment=OPENSEARCH_TMPDIR=/var/lib/opensearch-run/tmp
            Environment="OPENSEARCH_JAVA_OPTS=-Xms${heap} -Xmx${heap}"
            ExecStart=/opt/vf/opensearch/bin/opensearch
            Restart=on-failure
            RestartSec=5
            LimitNOFILE=65535
            LimitNPROC=4096
            TimeoutStartSec=300

            [Install]
            WantedBy=multi-user.target
          '';
        }
      ];

      # OPENSEARCH_HOME is the read-only release shared from the Mac; config, logs and data are local.
      runcmd = [
        "sysctl --system >/dev/null"
        "id opensearch >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin opensearch"
        "mkdir -p /etc/opensearch && cp -a /opt/vf/opensearch/config/. /etc/opensearch/ && chmod -R u+w /etc/opensearch"
        "cp /usr/local/lib/vf/opensearch.yml /etc/opensearch/opensearch.yml"
        "sed -i -e 's|=data$|=/var/lib/opensearch-run|' -e 's|logs/|/var/log/opensearch/|g' /etc/opensearch/jvm.options"
        "mkdir -p ${dataDir} /var/log/opensearch /var/lib/opensearch-run/logs /var/lib/opensearch-run/tmp"
        "chown -R opensearch:opensearch /etc/opensearch ${dataDir} /var/log/opensearch /var/lib/opensearch-run"
        "systemctl daemon-reload"
        "systemctl enable --now opensearch"
      ];

      ready = ''curl -sf "http://127.0.0.1:9200/_cluster/health?wait_for_nodes=${toString (builtins.length fleet.nodes)}&timeout=2s" | grep -q '"timed_out":false' '';

      notes = lib.optionalString (node.fleetIndex == 1) ''
        OpenSearch cluster '${fleet.name}': ${toString (builtins.length fleet.nodes)} node(s), ${settings.version}
          curl http://${if node.ip != null then node.ip else "$(vf ${node.name} ip)"}:9200/_cat/nodes?v'';
    };
}
