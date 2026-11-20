# Writing blueprints

A blueprint turns a VM or fleet into a working service: it installs software, writes config and
tells `vf` how to know the service is ready. It's one Nix file, and because it sees the whole fleet
it can write peer lists, join addresses and replication settings directly. Nothing gets templated
inside the guest.

This guide starts with a one-file web server, walks through a replicated
[Valkey](https://valkey.io) fleet (one primary, the rest replicas), then covers the full interface.
The built-in [`etcd`](../blueprints/etcd.nix), [`k3s`](../blueprints/k3s.nix),
[`opensearch`](../blueprints/opensearch.nix) and [`valkey`](../blueprints/valkey.nix) blueprints use
the same interface, so they make good further reading.

## 1. The smallest blueprint

```nix
# hello.nix
{
  config = { node, ... }: {
    packages = [ "nginx" ];
    write_files = [{ path = "/var/www/html/index.html"; content = "hello from ${node.name}\n"; }];
    ready = "curl -sf http://127.0.0.1/";
  };
}
```

```nix
# vf.nix (or inside mkProject { ... })
{
  blueprints.hello = import ./hello.nix;
  vms.web = { blueprints = [ "hello" ]; };
}
```

```sh
vf web up
curl http://$(vf web ip)/        # hello from web
```

`config` returns [cloud-config](https://cloudinit.readthedocs.io/en/latest/reference/examples.html):
`packages`, `write_files`, `runcmd`, `bootcmd`, `users` and so on, plus a few keys of its own like
`ready`. vfkit-nix merges it with the base config (your user, disks, mounts, `/etc/hosts`) and the
node's `cloudInit`.

## 2. A fleet-aware blueprint with settings

This is a trimmed-down version of the built-in [`valkey`](../blueprints/valkey.nix) blueprint, saved
under its own name so it doesn't clash with the built-in (the full version adds persistence on the
data disk and Fedora support):

```nix
# myvalkey.nix
{
  settings = {
    maxmemory = "256mb";
    extraConfig = { };
  };

  config = { lib, pkgs, node, fleet, settings }:
    let
      primary = builtins.head fleet.nodes;
      isPrimary = node.name == primary.name;
      addr = n: if n.privateIp != null then n.privateIp else n.ip;

      conf = {
        bind = "0.0.0.0";
        protected-mode = "no";
        maxmemory = settings.maxmemory;
      } // lib.optionalAttrs (!isPrimary) {
        replicaof = "${addr primary} 6379";
      } // settings.extraConfig;
    in
    {
      packages = [ "valkey-server" ];

      write_files = [{
        path = "/etc/valkey/vf.conf";
        content = lib.concatStrings (lib.mapAttrsToList (k: v: "${k} ${toString v}\n") conf);
      }];

      runcmd = [
        "echo 'include /etc/valkey/vf.conf' >> /etc/valkey/valkey.conf"
        "systemctl restart valkey-server"
      ];

      ready =
        if isPrimary then "valkey-cli ping | grep -q PONG"
        else "valkey-cli info replication | grep -q master_link_status:up";

      notes = lib.optionalString isPrimary ''
        valkey '${fleet.name}': primary ${node.name}, ${toString (builtins.length fleet.nodes - 1)} replica(s)
          vf ${node.name} ssh -- valkey-cli info replication'';
    };
}
```

```nix
{
  blueprints.myvalkey = import ./myvalkey.nix;

  fleets.cache = {
    blueprints = [ "myvalkey" ];
    count = 3;
    cpus = 1;
    memory = 1024;
    myvalkey.maxmemory = "512mb";
  };
}
```

```console
$ vf @cache up
...
[cache-1] vf: cache-1 ready (192.168.64.26)
[cache-1] valkey 'cache': primary cache-1, 2 replica(s)
[cache-1]   vf cache-1 ssh -- valkey-cli info replication
[cache-2] vf: cache-2 ready (192.168.64.24)
[cache-3] vf: cache-3 ready (192.168.64.25)
vf: @cache: all 3 nodes ready
$ vf cache-1 ssh -- valkey-cli set greeting hi
$ vf @cache ssh -- valkey-cli get greeting
```

What's going on:

- **`fleet.nodes`** lists every node in the fleet, in order, including this one. The first node is
  the primary, and the others point `replicaof` at its private IP.
- **`settings`** declares what users can set, with defaults. Users write `myvalkey.maxmemory = ...`
  on the fleet, a role or a VM. A misspelled key (`myvalkey.maxmem`) or a value of the wrong type
  (`myvalkey.maxmemory = 512`) fails before anything boots.
- **`extraConfig`** is an escape hatch for everything the blueprint doesn't model. The built-in
  blueprints all have one.
- **`ready`** runs as root inside the guest, again and again, until it succeeds. `vf up` only
  reports a node as ready after that.
- **`notes`** are printed after `up`. Print them on one node only, so a fleet doesn't repeat them.

## The interface

A blueprint file is an attribute set:

| Key | Required | |
|---|---|---|
| `settings` | no | Defaults for every setting users may change. A user value must have the same type as the default; a `null` default accepts any value. |
| `config` | yes | `{ lib, pkgs, node, fleet, settings }: { ... }` |

`config` receives:

| Argument | |
|---|---|
| `lib`, `pkgs` | nixpkgs for `aarch64-darwin`. Use `pkgs` to *fetch* things for the guest, not to run them there. |
| `node` | This node (below) |
| `fleet` | `{ name; nodes; }`: the fleet name and all of its nodes, each with the same fields as `node`. A VM is a fleet of one. |
| `settings` | This node's settings for this blueprint: defaults, then fleet values, then role values |

`node` fields:

| Field | |
|---|---|
| `name` | `etcd-1`, `search-data-2`, `dev` |
| `fleet`, `role`, `index` | Fleet name; role (`"node"` without roles, `"vm"` for VMs); 1-based index within the role |
| `fleetIndex` | 1-based position in the whole fleet |
| `os`, `cpus`, `memory`, `disk`, `mtu` | As configured |
| `data` | `{ size; mount; }`. Put state under `data.mount` when `data.size > 0`, so it survives `rebuild`. |
| `mounts`, `cloudInit`, `blueprints` | As configured |
| `ip`, `mac` | Static NAT IP or `null` (DHCP), and the NAT MAC |
| `privateNetwork`, `privateIp`, `privatePrefix`, `privateMac` | Private network, or `null` without one |
| `settings` | Settings for every blueprint on the node, by blueprint name: `n.settings.opensearch.nodeRoles` |

Keys `config` may return besides cloud-config:

| Key | |
|---|---|
| `ready` | A shell command, or a list of them. `vf up` waits until each succeeds (as root), up to `VF_READY_TIMEOUT`. |
| `artifacts` | `{ name = <directory>; }`. Each directory is shared read-only into the guest at `/opt/vf/<name>`. |
| `notes` | Text printed after `vf up` |

When a node has several blueprints, they're applied in order: lists are appended, attribute sets
merged, and later scalars win. The node's own `cloudInit` comes last.

## Recipes

### Install a pinned upstream release

Distribution packages are the easiest route, but they differ between Debian and Fedora, and every
node downloads them again on every rebuild. For a specific upstream version, fetch it once on the
Mac and share it in as an artifact:

```nix
{
  settings = {
    version = "1.2.3";
    hash = "sha256-AAAA...";
  };

  config = { pkgs, settings, ... }: {
    artifacts.mytool = pkgs.fetchzip {
      url = "https://example.com/mytool-${settings.version}-linux-arm64.tar.gz";
      inherit (settings) hash;
    };
    runcmd = [ "install -m 0755 /opt/vf/mytool/mytool /usr/local/bin/" ];
  };
}
```

The download happens once into the Nix store and is reused by every node and every rebuild. With
`hash = "";` the first build fails and prints the real hash. A single file (`pkgs.fetchurl`) has to
be put in a directory first; see the `k3s` blueprint.

### Peers and addresses

Use the private IP for node-to-node traffic: macOS blocks VM-to-VM traffic on the NAT network.
Fleets get a private network automatically when they have more than one node, but a user can turn
it off, so fail clearly:

```nix
addr = n: if n.privateIp != null then n.privateIp else n.ip;
...
assert lib.assertMsg (lib.all (n: addr n != null) fleet.nodes)
  "myapp: fleet '${fleet.name}' needs the private network or static IPs";
```

Node names resolve inside a fleet through `/etc/hosts`, so `etcd-2` works in config files too.

### Values known only at boot

Some things aren't known at build time: a DHCP address, an interface name. Write a script that
fills them in, as the `k3s` blueprint does:

```nix
write_files = [{
  path = "/usr/local/lib/vf/myapp-setup.sh";
  permissions = "0755";
  content = ''
    set -eu
    nat_ip=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
    sed "s/@NAT_IP@/$nat_ip/" /usr/local/lib/vf/myapp.yaml > /etc/myapp.yaml
  '';
}];
runcmd = [ "/usr/local/lib/vf/myapp-setup.sh" ];
```

### Config files

YAML is a superset of JSON, so `builtins.toJSON` writes valid YAML config:
`content = builtins.toJSON config + "\n";`. Merge `settings.extraConfig` last, so users can
override anything the blueprint generates.

### Roles

Roles are just names. Give them meaning in the blueprint, as `k3s` does with `agent`:

```nix
isWorker = node.role == "worker";
leaders = lib.filter (n: n.role != "worker") fleet.nodes;
```

## Using and sharing blueprints

- **In a project:** `blueprints.myapp = import ./myapp.nix;`, then `blueprints = [ "myapp" ];` on a
  VM or fleet.
- **Override a built-in:** a project blueprint with the same name replaces it. Copy
  [`blueprints/etcd.nix`](../blueprints/etcd.nix) next to your project and adapt it.
- **Add a built-in:** drop `<name>.nix` into [`blueprints/`](../blueprints); it's picked up by file
  name.

## Debugging a blueprint

```sh
vf myapp-1 show                                   # the merged cloud-config, network config, vfkit command
vf myapp-1 up                                     # boots, then shows which ready check it waits on
vf myapp-1 ssh -- sudo cloud-init status --long
vf myapp-1 ssh -- sudo cat /var/log/cloud-init-output.log
vf myapp-1 ssh -- sudo journalctl -u myapp -b
vf @myapp rebuild                                 # try again from a clean OS
```

Evaluation errors (a bad setting, a failed `assert`) show up on any `vf` command, before anything
boots.
