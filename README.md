# vfkit-nix

Disposable Linux VMs and small clusters on your Apple Silicon Mac, described in a few lines of Nix.

```console
$ vf @etcd up
[etcd-1] vf: booting etcd-1 ... 192.168.64.101
[etcd-2] vf: booting etcd-2 ... 192.168.64.102
[etcd-3] vf: booting etcd-3 ... 192.168.64.103
...
vf: @etcd: all 3 nodes ready                      # about 10 s for a 3-node etcd cluster
```

vfkit-nix turns a short description of VMs and fleets into cloud-init files and a
[vfkit](https://github.com/crc-org/vfkit) command per node. A small CLI, `vf`, boots them, waits
until they're actually ready, and gets you a shell.

- **Ready-made stacks:** a dev VM and 3-node **etcd**, **k3s**, **OpenSearch** and **Valkey**
  clusters, each one `vf ... up` away.
- **Throwaway by design:** `vf dev rebuild` gives you a fresh OS in seconds while `/data` survives.
- **No root, no daemon, nothing installed globally.** Everything runs as you, from the Nix store.
- **Readable:** every node is a folder of plain files you can inspect with `vf <node> show`.
- **Extensible:** a blueprint for your own software is one short Nix file
  ([guide](docs/blueprints.md)).

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [The stacks](#the-stacks): [dev VM](#dev-vm) · [etcd](#etcd) · [k3s](#k3s) · [OpenSearch](#opensearch) ·
  [Valkey](#valkey)
- [Configuration](#configuration): [node options](#node-options) · [fleets](#fleets) ·
  [blueprint settings](#blueprint-settings) · [examples](#more-examples)
- [Commands](#commands)
- [Data disks](#data-disks)
- [Networking](#networking)
- [Using vfkit-nix in your project](#using-vfkit-nix-in-your-project)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- Further reading: [Writing blueprints](docs/blueprints.md) · [How it works](docs/internals.md)

## Requirements

- An Apple Silicon Mac running macOS 13 or later. Guests are aarch64 Linux (Debian 13 or Fedora 44).
- [Nix](https://nixos.org/download/) with flakes enabled. The
  [Determinate installer](https://determinate.systems/nix-installer/) enables them by default;
  otherwise add `experimental-features = nix-command flakes` to `~/.config/nix/nix.conf`.

## Quick start

```sh
mkdir mylab && cd mylab
nix flake init -t github:melonlorrd/vfkit-nix    # a dev VM; see the other templates below
git init && git add flake.nix                    # flakes only see files tracked by git
nix develop                                      # puts `vf` on your PATH

vf dev up          # first run downloads the Debian image (~320 MB); about a minute
vf dev ssh         # you're logged in as your Mac username, with passwordless sudo
vf dev stop        # shut down; `vf dev up` boots it again with everything intact
vf dev rebuild     # brand-new OS disk, same /data
vf dev destroy --data
```

The `git init` step is only needed if the folder isn't already in a git repository.

Templates (`nix flake init -t github:melonlorrd/vfkit-nix#<name>`):

| Template | What you get | Start it with | RAM |
|---|---|---|---|
| `vm` (default) | Debian dev VM with a 20 GB `/data` disk and your project folder shared at `/mnt/project` | `vf dev up` | 4 GB |
| `etcd` | 3-node etcd cluster | `vf @etcd up` | 3 GB |
| `k3s` | k3s with 1 server and 2 agents | `vf @k3s up` | 6 GB |
| `opensearch` | 3-node OpenSearch cluster | `vf @opensearch up` | 6 GB |
| `valkey` | Valkey with 1 primary and 2 replicas | `vf @valkey up` | 3 GB |
| `plain` | The dev VM as a `vf.nix` file, for folders without a `flake.nix` ([details](#without-a-flake-vfnix)) | `vf dev up` | 4 GB |

Each template is a single short file with every useful option written out. Edit it, then run
`vf <node> rebuild` (or `vf @<fleet> rebuild`) to apply the change.

Just want to look around first? This repository is itself a project with all five stacks in
[`examples/default.nix`](examples/default.nix):

```sh
git clone https://github.com/melonlorrd/vfkit-nix && cd vfkit-nix
nix develop
vf list
```

## The stacks

### Dev VM

```nix
vms.dev = {
  os = "debian";        # "debian" (13) or "fedora" (44)
  cpus = 2;
  memory = 4096;        # MiB
  disk = 20;            # GiB, recreated by `vf dev rebuild`
  data.size = 20;       # GiB at /data, kept across `vf dev rebuild`
  ip = null;            # static NAT IP such as "192.168.64.50"; null = DHCP
  mounts = [            # source: relative to this folder, ~/..., or absolute
    { tag = "project"; source = "."; target = "/mnt/project"; }
  ];
  cloudInit.packages = [ "git" "curl" "build-essential" ];
};
```

```sh
vf dev up
vf dev ssh                       # interactive shell
vf dev ssh -- make -C /mnt/project test
ssh -i ~/.local/share/vfkit-nix/id_ed25519 "$USER@$(vf dev ip)"   # plain ssh/scp/rsync work too
```

`source = "."` is the folder with your `flake.nix` (or `vf.nix`): put your code next to it and it
shows up live at `/mnt/project`, edits flowing both ways, so you edit on the Mac and build in the VM.
Share other folders by adding entries, such as
`{ tag = "notes"; source = "~/notes"; target = "/mnt/notes"; }`. Anything that must survive a
rebuild but shouldn't live on the Mac goes in `/data`.

### etcd

```nix
fleets.etcd = {
  blueprints = [ "etcd" ];
  count = 3;                    # etcd-1 .. etcd-3
  cpus = 1;
  memory = 1024;
  data.size = 5;                # etcd data lives on /data/etcd
  ipStart = "192.168.64.101";   # etcd-1 = .101, etcd-2 = .102, ...
  etcd.extraConfig = {          # any etcd config-file key
    auto-compaction-mode = "periodic";
    auto-compaction-retention = "1h";
  };
};
```

```sh
vf @etcd up
vf etcd-1 ssh -- etcdctl member list -w table
vf @etcd ssh -- etcdctl endpoint status            # runs on every node
export ETCDCTL_ENDPOINTS=http://192.168.64.101:2379,http://192.168.64.102:2379,http://192.168.64.103:2379
etcdctl put hello world                            # from the Mac, if you have etcdctl
```

Every node is a voting member. Peers talk over the private network, clients connect on port 2379 of
any node's NAT IP. Plain HTTP, no auth.

### k3s

```nix
fleets.k3s = {
  blueprints = [ "k3s" ];
  ipStart = "192.168.64.111";   # roles take IPs alphabetically: agents .111 .112, server .113
  k3s.token = "change-me";
  roles.server = {
    count = 1;                  # 3 = HA with embedded etcd
    cpus = 2;
    memory = 2048;
    k3s.extraConfig.disable = [ "traefik" ];   # server-only config.yaml keys go here
  };
  roles.agent = { count = 2; cpus = 2; memory = 2048; };
};
```

```sh
vf @k3s up
vf k3s-server-1 ssh -- kubectl get nodes -o wide

# kubectl from the Mac
vf k3s-server-1 ssh -- cat /etc/rancher/k3s/k3s.yaml | sed "s/127.0.0.1/$(vf k3s-server-1 ip)/" > kubeconfig
export KUBECONFIG=$PWD/kubeconfig
kubectl get pods -A
```

Nodes named `agent` run `k3s agent`; every other role runs `k3s server`. With more than one server,
the first one starts the cluster with embedded etcd and the rest join it. Flannel runs over the
private network, so pods on different nodes reach each other. A single-node k3s is just
`vms.kube = { blueprints = [ "k3s" ]; memory = 2048; };`.

### OpenSearch

```nix
fleets.opensearch = {
  blueprints = [ "opensearch" ];
  count = 3;                    # every node is cluster_manager + data + ingest
  cpus = 2;
  memory = 2048;
  data.size = 10;               # indices live on /data/opensearch
  ipStart = "192.168.64.121";
  opensearch.heap = "1g";       # default: half of memory
  opensearch.extraConfig = {    # any opensearch.yml key
    "cluster.routing.allocation.disk.threshold_enabled" = false;
  };
};
```

```sh
vf @opensearch up
curl http://192.168.64.121:9200/_cat/nodes?v
curl -XPUT http://192.168.64.121:9200/logs -H 'content-type: application/json' \
  -d '{"settings":{"number_of_shards":3,"number_of_replicas":1}}'
```

The security plugin is disabled, so it's plain HTTP on port 9200 with no login. For dedicated
manager and data nodes, use roles:

```nix
fleets.search = {
  blueprints = [ "opensearch" ];
  ipStart = "192.168.64.131";
  roles.manager = { count = 1; memory = 1536; opensearch.nodeRoles = [ "cluster_manager" ]; };
  roles.data    = { count = 2; memory = 3072; data.size = 20; opensearch.nodeRoles = [ "data" "ingest" ]; };
};
```

### Valkey

```nix
fleets.valkey = {
  blueprints = [ "valkey" ];
  count = 3;                    # valkey-1 is the primary, the rest replicate from it
  cpus = 1;
  memory = 1024;
  data.size = 5;                # RDB/AOF files live on /data/valkey
  ipStart = "192.168.64.131";
  valkey.maxmemory = "512mb";   # default: half of memory
  valkey.extraConfig = {        # any valkey.conf directive
    maxmemory-policy = "allkeys-lru";
  };
};
```

```sh
vf @valkey up
vf valkey-1 ssh -- valkey-cli set greeting hello
vf @valkey ssh -- valkey-cli get greeting          # replicated to every node
valkey-cli -h 192.168.64.131                       # from the Mac, if you have valkey-cli or redis-cli
```

Valkey comes from the distribution's packages, with append-only persistence turned on. Replicas are
read-only. It has no password (`protected-mode no`); set one with
`valkey.extraConfig.requirepass = "..."` and `masterauth` on the replicas if you need it. A single
cache is `vms.cache = { blueprints = [ "valkey" ]; };`.

## Configuration

A project is an attribute set with up to three keys:

```nix
{
  vms.<name> = { ... };          # single machines
  fleets.<name> = { ... };       # groups of nodes, usually with a blueprint
  blueprints.<name> = import ./my-blueprint.nix;   # your own blueprints (optional)
}
```

It goes into `vfkit-nix.lib.mkProject { ... }` in a `flake.nix`, or into a plain `vf.nix` file.
Everything is checked before anything boots: a typo such as `opensarch.heap` or a string where a
number belongs fails with a message naming the node and the option. `vf` re-reads the project on
every call, so edit, then `vf <node> rebuild`.

### Node options

Valid on `vms.<name>`, on `fleets.<name>` (default for every node), and on `fleets.<name>.roles.<role>`
(overrides the fleet's value for that role).

| Option | Default | Description |
|---|---|---|
| `os` | `"debian"` | `"debian"` (13) or `"fedora"` (44). Images are pinned in [`images.nix`](images.nix). |
| `cpus` | `2` | Virtual CPUs |
| `memory` | `2048` | MiB |
| `disk` | `20` | OS disk in GiB. Sparse, so it only uses what the guest writes. Can grow, not shrink. |
| `data.size` | `0` | Data disk in GiB, `0` for none. Survives `rebuild`; see [Data disks](#data-disks). |
| `data.mount` | `"/data"` | Where the data disk is mounted |
| `mounts` | `[]` | Folders shared from the Mac: `[{ tag = "src"; source = "."; target = "/mnt/src"; }]`. `source` is relative to the project folder, `~/...`, or absolute; `tag` must be unique per node. |
| `cloudInit` | `{}` | Any [cloud-config](https://cloudinit.readthedocs.io/en/latest/reference/examples.html), merged last. Lists are appended, attribute sets merged. |
| `mtu` | `1280` | MTU of the NAT interface; see [Networking](#networking) |
| `blueprints` | `[]` | Blueprints to apply, in order (on `vms` and `fleets`, not roles) |

`vms.<name>` also takes:

| Option | Default | Description |
|---|---|---|
| `ip` | `null` | Static NAT IP (use `192.168.64.100` and up). `null` = DHCP. |
| `private` | `null` | Join a private network: `{ network = "lab"; ip = "10.10.0.5"; prefix = 24; }` |

### Fleets

| Option | Default | Description |
|---|---|---|
| `count` | `1` | Number of nodes, named `<fleet>-1` … `<fleet>-N` |
| `roles.<role>` | `{}` | Groups of nodes instead of `count`, named `<fleet>-<role>-1` …. Takes `count` plus any node option or blueprint setting. |
| `ipStart` | `null` | Static NAT IP of the first node; the others count up from it. `null` = DHCP. |
| `private.enable` | auto | Private VM-to-VM network. On when the fleet has more than one node. |
| `private.ipStart` | `"10.100.0.11"` | Private IP of the first node |
| `private.network` | fleet name | Fleets (and VMs) with the same network name share one network |
| `private.prefix` | `24` | Prefix length |

Nodes are numbered with roles in **alphabetical** order, which decides IPs: in the k3s example
`agent-1` and `agent-2` get `.111` and `.112`, and `server-1` gets `.113`.

### Blueprint settings

Each blueprint has its own settings, set under the blueprint's name on a VM, fleet or role, such
as `k3s.token = "x";`. Role settings override fleet settings.

| Setting | Default | Description |
|---|---|---|
| **etcd** | | |
| `etcd.version` | `"3.7.3"` | Release to install (set `hash` too) |
| `etcd.hash` | pinned | Hash of the release tarball |
| `etcd.extraConfig` | `{}` | Keys for etcd's [config file](https://etcd.io/docs/latest/op-guide/configuration/), overriding the generated ones |
| **k3s** | | |
| `k3s.version` | `"v1.37.2+k3s1"` | Release to install (set `hash` too) |
| `k3s.hash` | pinned | Hash of the `k3s-arm64` binary |
| `k3s.token` | `"vfkit-nix"` | Shared cluster secret |
| `k3s.extraConfig` | `{}` | Keys for k3s's [config.yaml](https://docs.k3s.io/installation/configuration#configuration-file). Server-only keys (`disable`, `cluster-cidr`, …) belong on the server role, because agents reject them. |
| **opensearch** | | |
| `opensearch.version` | `"3.9.0"` | Release to install (set `hash` too) |
| `opensearch.hash` | pinned | Hash of the release tarball |
| `opensearch.nodeRoles` | `[ "cluster_manager" "data" "ingest" ]` | `node.roles` of this node |
| `opensearch.heap` | half of `memory` | JVM heap, such as `"1g"` or `"768m"` |
| `opensearch.extraConfig` | `{}` | Keys for `opensearch.yml`, overriding the generated ones |
| **valkey** | | |
| `valkey.maxmemory` | half of `memory` | Memory limit, such as `"512mb"` |
| `valkey.extraConfig` | `{}` | [valkey.conf](https://valkey.io/topics/valkey.conf/) directives, overriding the generated ones |

**Changing a version** (etcd, k3s, OpenSearch; Valkey uses the distribution's package): set `version`, and set `hash = "";`. The first build fails and prints the
correct hash (`got: sha256-…`); paste it in. Releases are downloaded once into the Nix store and
shared read-only with every node, so rebuilds never download them again.

### More examples

A Fedora VM with extra packages, a service and a static IP:

```nix
vms.box = {
  os = "fedora";
  ip = "192.168.64.60";
  cloudInit = {
    packages = [ "podman" ];
    runcmd = [ "systemctl enable --now podman.socket" ];
  };
};
```

Two fleets on one private network, so the app nodes can reach etcd by name:

```nix
fleets.etcd = { blueprints = [ "etcd" ]; count = 3; memory = 1024; private.network = "lab"; };
fleets.app = {
  count = 2;
  private = { network = "lab"; ipStart = "10.100.0.51"; };   # must not overlap with etcd's .11-.13
  cloudInit.write_files = [{ path = "/etc/app.env"; content = "ETCD=http://etcd-1:2379\n"; }];
};
```

Note that `/etc/hosts` only lists a node's own fleet, so on the app nodes use IPs, or add the
names with `cloudInit`.

A 3-server HA k3s with labels on the agents:

```nix
fleets.ha = {
  blueprints = [ "k3s" ];
  ipStart = "192.168.64.141";
  roles.server = { count = 3; memory = 2048; };
  roles.agent = { count = 2; k3s.extraConfig.node-label = [ "tier=batch" ]; };
};
```

Your own software: see [Writing blueprints](docs/blueprints.md).

## Commands

| Command | |
|---|---|
| `vf list` | Every node: state (`running`, `stopped`, `absent`), CPUs, memory, IPs, data disk usage |
| `vf <node> up` | Build, create disks on first use, boot, wait for SSH, cloud-init and the blueprint's ready check |
| `vf <node> ssh` | Log in |
| `vf <node> ssh -- <cmd>` | Run a command |
| `vf <node> stop` | Graceful shutdown (falls back to `kill` after 60 s) |
| `vf <node> kill` | Hard power-off |
| `vf <node> status` | One-line state; also what `vf <node>` alone does |
| `vf <node> ip` | NAT IP, reachable from the Mac |
| `vf <node> console` | Follow the serial console (boot log) |
| `vf <node> show` | Print the node's generated cloud-init files and vfkit command |
| `vf <node> destroy [--data]` | Delete the VM. The data disk is kept unless you pass `--data`. |
| `vf <node> rebuild [--data]` | `destroy` + `up` |
| `vf @<fleet> up \| stop \| kill \| destroy \| rebuild` | The same for every node of a fleet, in parallel |
| `vf @<fleet> status` | Status of every node in the fleet |
| `vf @<fleet> ssh -- <cmd>` | Run a command on each node in turn |
| `vf net` / `vf net stop <network>` | List / stop private network switches |

Environment variables:

| Variable | Default | |
|---|---|---|
| `VF_FLAKE` | set by `nix develop` | Project flake (a path or any flake ref), instead of searching upward |
| `VF_FILE` | | A `vf.nix`-style file, instead of searching upward |
| `VF_HOME` | `~/.local/share/vfkit-nix` | Where disks, logs and the SSH key live |
| `VF_READY_TIMEOUT` | `600` | Seconds to wait for each ready check |

## Data disks

`data.size > 0` adds a second disk, formatted ext4 on first boot, mounted at `data.mount`, owned by
your user. The built-in blueprints keep their state there when it exists (`/data/etcd`,
`/data/opensearch`, `/data/valkey`).

| | OS disk | Data disk |
|---|---|---|
| `stop` → `up` | kept | kept |
| `rebuild`, `destroy` | **deleted** | kept |
| `rebuild --data`, `destroy --data` | deleted | **deleted** |

To grow a data disk, raise `data.size` and restart the node. Disks are sparse files, so a 20 GB disk
uses only what's written to it; `vf list` shows the real usage.

## Networking

Each node has up to two network cards:

- **NAT** (always): `192.168.64.0/24`, reaches the internet and the Mac, and the Mac reaches it at
  `vf <node> ip`. macOS doesn't let VMs talk to each other on this network.
- **Private** (fleets with more than one node, or `private` on a VM): a VM-to-VM network run by a
  small switch process under your user. Only VMs on it can see it; the Mac can't. Every node's
  `/etc/hosts` lists its fleet, so `etcd-2` resolves.

For static NAT IPs use `.100` and up; macOS hands out DHCP leases from the bottom of the range.
There's no port forwarding to `localhost`; connect to the node's IP.

The NAT MTU defaults to 1280 because full-size packets through macOS NAT are silently dropped on
some uplinks (TLS downloads hang while `ping` works). Raise `mtu` if your network is fine with 1500.

More detail, including how the private switch works: [How it works](docs/internals.md#networking).

## Using vfkit-nix in your project

### Your own flake.nix

```nix
{
  inputs.vfkit-nix.url = "github:melonlorrd/vfkit-nix";

  outputs = { vfkit-nix, ... }: vfkit-nix.lib.mkProject {
    vms.dev = { memory = 4096; data.size = 20; };
    fleets.etcd = { blueprints = [ "etcd" ]; count = 3; memory = 1024; };
  };
}
```

`mkProject` also accepts a path, for example `mkProject ./vms.nix`. It returns `devShells.default`
(with `vf`), `packages.vf`, and `legacyPackages.{nodes,vfInfo}`, all for `aarch64-darwin`.
`flake.lock` pins the vfkit-nix version; `nix flake update vfkit-nix` upgrades it.

### Inside an existing flake

`vf` only needs `legacyPackages.aarch64-darwin.{nodes,vfInfo}` from your flake and `vf` on PATH:

```nix
{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  inputs.vfkit-nix.url = "github:melonlorrd/vfkit-nix";

  outputs = { nixpkgs, vfkit-nix, ... }:
    let
      pkgs = nixpkgs.legacyPackages.aarch64-darwin;
      lab = vfkit-nix.lib.mkProject {
        vms.db = { memory = 2048; data.size = 10; cloudInit.packages = [ "postgresql" ]; };
      };
    in
    {
      inherit (lab) legacyPackages;
      devShells.aarch64-darwin.default = pkgs.mkShell {
        packages = [ pkgs.go vfkit-nix.packages.aarch64-darwin.vf ];
      };
    };
}
```

If you already have `legacyPackages`, merge them:
`legacyPackages.aarch64-darwin = yours // lab.legacyPackages.aarch64-darwin;`.

### Without a flake (vf.nix)

Put the project in a `vf.nix` file and run `vf` from the vfkit-nix flake:

```nix
# vf.nix
{
  vms.dev = { memory = 4096; data.size = 20; };
  blueprints.myapp = import ./myapp.nix;
}
```

```sh
nix shell github:melonlorrd/vfkit-nix      # `vf` on PATH in this shell
vf dev up
```

`vf` evaluates `vf.nix` with the vfkit-nix version it came from; pin it with
`nix shell github:melonlorrd/vfkit-nix/<tag-or-commit>`. If a folder has both files, `vf.nix` wins.

## Troubleshooting

Start with `vf <node> show` (what was generated) and `vf <node> console` (what the VM is doing).

| Symptom | What to do |
|---|---|
| `timed out waiting for ssh` | `vf <node> console`. If the VM booted fine, see the Local Network row below. |
| `cloud-init status: error` | `vf <node> ssh -- sudo cat /var/log/cloud-init-output.log`. Often a package that doesn't exist on that OS. |
| `apt`/`dnf` hangs, `ping` works | MTU: lower `mtu`, or check `vf <node> ssh -- curl -4 -I https://deb.debian.org` |
| `ready check timed out` | The service didn't come up: `vf <node> ssh -- sudo journalctl -b -p warning` |
| `vfkit exited` | `~/.local/share/vfkit-nix/<node>/vfkit.log` |
| `mount source … is not a directory` | Create the folder on the Mac, or fix `mounts` |
| A Nix-installed tool can't reach VM IPs | Allow your terminal under System Settings → Privacy & Security → Local Network |
| `hash mismatch … got: sha256-…` | A version or URL changed; put the `got:` hash in the setting |
| `vf list` shows `orphan` | State of a node you removed from the project; delete it with the printed `rm -rf` |

**Disk space:** VM disks are copy-on-write clones of one base image per OS, so a node costs only
what it writes. `rm -rf ~/.local/share/vfkit-nix/images` frees the base images (existing VMs don't
need them); `nix store gc` frees downloaded releases after you stop the VMs.

## Limitations

- Apple Silicon only; aarch64 Debian 13 and Fedora 44 guests. Blueprints are tested on Debian.
- Fleet sizes are fixed: change `count` or `roles`, then `vf @<fleet> rebuild --data`.
- Memory is the real limit on a laptop. Add it up before starting several fleets.
- Development defaults, not production: a fixed k3s token, OpenSearch without security, etcd
  without TLS.
