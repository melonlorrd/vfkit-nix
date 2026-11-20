{
  settings = {
    version = "3.7.3";
    hash = "sha256-9R2x+aL6zGCFRTAj1QFp96pohHuycjd0Y7vJ2WEJ4ao=";
    extraConfig = { };
  };

  config = { lib, pkgs, node, fleet, settings }:
    let
      peerAddr = n:
        if n.privateIp != null then n.privateIp
        else if n.ip != null then n.ip
        else if builtins.length fleet.nodes == 1 then "127.0.0.1"
        else throw "etcd: multi-node fleet '${fleet.name}' needs the private network or static IPs";
      me = peerAddr node;
      macUrl = n: "http://${if n.ip != null then n.ip else "<vf ${n.name} ip>"}:2379";

      dataDir = if node.data.size > 0 then "${node.data.mount}/etcd" else "/var/lib/etcd";

      config = {
        name = node.name;
        data-dir = dataDir;
        listen-peer-urls = "http://${me}:2380";
        initial-advertise-peer-urls = "http://${me}:2380";
        initial-cluster = lib.concatMapStringsSep "," (n: "${n.name}=http://${peerAddr n}:2380") fleet.nodes;
        initial-cluster-token = fleet.name;
        initial-cluster-state = "new";
        listen-client-urls = "http://0.0.0.0:2379";
        advertise-client-urls = "http://${me}:2379";
      } // settings.extraConfig;
    in
    {
      artifacts.etcd = pkgs.fetchzip {
        url = "https://github.com/etcd-io/etcd/releases/download/v${settings.version}/etcd-v${settings.version}-linux-arm64.tar.gz";
        inherit (settings) hash;
      };

      write_files = [
        { path = "/etc/etcd/etcd.yaml"; content = builtins.toJSON config + "\n"; }
        {
          path = "/etc/systemd/system/etcd.service";
          content = ''
            [Unit]
            Description=etcd
            After=network-online.target
            Wants=network-online.target

            [Service]
            Type=notify
            User=etcd
            ExecStart=/usr/local/bin/etcd --config-file /etc/etcd/etcd.yaml
            Restart=on-failure
            RestartSec=2
            LimitNOFILE=65536

            [Install]
            WantedBy=multi-user.target
          '';
        }
      ];

      runcmd = [
        "install -m 0755 /opt/vf/etcd/etcd /opt/vf/etcd/etcdctl /opt/vf/etcd/etcdutl /usr/local/bin/"
        "id etcd >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin etcd"
        "mkdir -p ${dataDir} && chown etcd:etcd ${dataDir} && chmod 700 ${dataDir}"
        "systemctl daemon-reload"
        "systemctl enable --now etcd"
      ];

      ready = "/usr/local/bin/etcdctl --endpoints=http://127.0.0.1:2379 endpoint health";

      notes = lib.optionalString (node.fleetIndex == 1) ''
        etcd cluster '${fleet.name}': ${toString (builtins.length fleet.nodes)} member(s), v${settings.version}
          vf ${node.name} ssh -- etcdctl member list -w table
          endpoints (from the Mac): ${lib.concatMapStringsSep "," macUrl fleet.nodes}'';
    };
}
