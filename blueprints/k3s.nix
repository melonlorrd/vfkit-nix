{
  settings = {
    version = "v1.37.2+k3s1";
    hash = "sha256-p3nM8eXi4zpi9aKcLxwLv5lDHhAFedTBDwqgdCpqqEs=";
    token = "vfkit-nix";
    extraConfig = { };
  };

  config = { lib, pkgs, node, fleet, settings }:
    let
      isAgent = n: n.role == "agent";
      servers = lib.filter (n: !isAgent n) fleet.nodes;
      first = builtins.head servers;
      isFirst = node.name == first.name;
      clusterAddr = n: if n.privateIp != null then n.privateIp else n.ip;
      joinUrl = "https://${clusterAddr first}:6443";
      service = if isAgent node then "k3s-agent" else "k3s";

      # @NAT_IP@ and @PRIVATE_IF@ are only known at boot (DHCP, interface names).
      config = {
        token = settings.token;
        node-external-ip = "@NAT_IP@";
      } // lib.optionalAttrs (node.privateIp != null) {
        node-ip = node.privateIp;
        flannel-iface = "@PRIVATE_IF@";
      } // lib.optionalAttrs (!isFirst) {
        server = joinUrl;
      } // lib.optionalAttrs (!isAgent node) {
        tls-san = [ "@NAT_IP@" ];
        write-kubeconfig-mode = "0644";
      } // lib.optionalAttrs (!isAgent node && node.privateIp != null) {
        advertise-address = node.privateIp;
      } // lib.optionalAttrs (isFirst && builtins.length servers > 1) {
        cluster-init = true;
      } // settings.extraConfig;

      setup = ''
        set -eu
        nat_ip=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
        private_if=${if node.privateIp != null then "$(ip -o -4 addr show to ${node.privateIp} | awk '{print $2}')" else "none"}
        mkdir -p /etc/rancher/k3s
        sed -e "s/@NAT_IP@/$nat_ip/g" -e "s/@PRIVATE_IF@/$private_if/g" /usr/local/lib/vf/k3s.yaml > /etc/rancher/k3s/config.yaml
        install -m 0755 /opt/vf/k3s/k3s /usr/local/bin/k3s
        for t in kubectl crictl ctr; do ln -sf k3s /usr/local/bin/$t; done
        systemctl daemon-reload
        systemctl enable --now ${service}
      '';
    in
    assert lib.assertMsg (servers != [ ]) "k3s: fleet '${fleet.name}' has no server (every role except 'agent' is a server)";
    assert lib.assertMsg (builtins.length fleet.nodes == 1 || clusterAddr first != null)
      "k3s: multi-node fleet '${fleet.name}' needs the private network or static IPs";
    {
      artifacts.k3s = pkgs.runCommand "k3s-${lib.replaceStrings [ "+" ] [ "-" ] settings.version}" { } ''
        install -D -m 0755 ${pkgs.fetchurl {
          url = "https://github.com/k3s-io/k3s/releases/download/${lib.escapeURL settings.version}/k3s-arm64";
          inherit (settings) hash;
        }} $out/k3s
      '';

      write_files = [
        { path = "/usr/local/lib/vf/k3s.yaml"; content = builtins.toJSON config + "\n"; }
        { path = "/usr/local/lib/vf/k3s-setup.sh"; content = setup; permissions = "0755"; }
        {
          path = "/etc/systemd/system/${service}.service";
          content = ''
            [Unit]
            Description=k3s ${if isAgent node then "agent" else "server"}
            Wants=network-online.target
            After=network-online.target

            [Service]
            Type=${if isAgent node then "exec" else "notify"}
            ExecStartPre=-/sbin/modprobe br_netfilter
            ExecStartPre=-/sbin/modprobe overlay
            ExecStart=/usr/local/bin/k3s ${if isAgent node then "agent" else "server"}
            KillMode=process
            Delegate=yes
            LimitNOFILE=1048576
            LimitNPROC=infinity
            LimitCORE=infinity
            TasksMax=infinity
            TimeoutStartSec=0
            Restart=always
            RestartSec=5s

            [Install]
            WantedBy=multi-user.target
          '';
        }
      ];

      runcmd = [ "/usr/local/lib/vf/k3s-setup.sh" ];

      ready =
        if isAgent node then "systemctl is-active --quiet k3s-agent"
        else if isFirst then
          ''test "$(k3s kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l)" -ge ${toString (builtins.length fleet.nodes)}''
        else "k3s kubectl get --raw /readyz >/dev/null";

      notes = lib.optionalString isFirst ''
        k3s cluster '${fleet.name}': ${toString (builtins.length servers)} server(s), ${toString (builtins.length fleet.nodes - builtins.length servers)} agent(s), ${settings.version}
          vf ${node.name} ssh -- kubectl get nodes -o wide
          kubeconfig for the Mac:
            vf ${node.name} ssh -- cat /etc/rancher/k3s/k3s.yaml | sed "s/127.0.0.1/$(vf ${node.name} ip)/" > kubeconfig-${fleet.name}'';
    };
}
