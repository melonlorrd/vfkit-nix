"""vf: lifecycle only. Nix renders each node; vf builds it, prepares its state dir and runs bin/run.

Started by the `vf` wrapper in flake.nix, which sets VF_SWITCH, VF_SELF and puts qemu-img on PATH.
"""
import http.client
import json
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from subprocess import DEVNULL, PIPE, STDOUT

STATE = Path(os.environ.get("VF_HOME") or Path.home() / ".local/share/vfkit-nix")
NET = STATE / "net"
KEY = STATE / "id_ed25519"
LEASES = Path("/var/db/dhcpd_leases")
USER = os.environ.get("USER") or os.getlogin()
# Apple's own ssh: macOS Local Network privacy can block other binaries from reaching VM IPs.
SSH = "/usr/bin/ssh"
SSH_OPTS = ["-F", "/dev/null", "-i", str(KEY), "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=3"]
SELF = [sys.executable, os.path.abspath(__file__)]
GiB = 1 << 30
ROW = "{:<20} {:<7} {:<8} {:>4} {:>6}  {:<15} {:<15} {}"

USAGE = """\
usage: vf list                          every node in the project and its state
       vf <node> up                     create on first use, boot, wait until ready
       vf <node> ssh [cmd...]           log in, or run a command
       vf <node> stop | kill            graceful shutdown | hard power-off
       vf <node> status | ip            state | NAT IP (reachable from the Mac)
       vf <node> console                follow the serial console
       vf <node> show                   print the generated cloud-init files and vfkit command
       vf <node> destroy [--data]       delete the VM; the data disk is kept unless --data
       vf <node> rebuild [--data]       destroy + up
       vf @<fleet> up | stop | kill | destroy | rebuild | status
                                        the same, for every node of a fleet (in parallel)
       vf @<fleet> ssh -- <cmd>         run a command on every node, one after another
       vf net [list | stop <network>]   private network switches

examples:
       vf dev up && vf dev ssh
       vf @etcd up
       vf @etcd ssh -- etcdctl endpoint status
       vf dev rebuild                   fresh OS, same /data

vf looks for vf.nix or flake.nix in this directory and its parents.
Override with VF_FILE=<file.nix> or VF_FLAKE=<flake ref>."""


class Fail(Exception):
    pass


def die(msg):
    raise Fail(msg)


def say(msg, end="\n"):
    print(f"vf: {msg}", end=end, flush=True)


def quiet(cmd):
    return subprocess.run(cmd, stdin=DEVNULL, stdout=DEVNULL, stderr=DEVNULL).returncode == 0


def pid_alive(pidfile):
    try:
        os.kill(int(pidfile.read_text()), 0)
        return True
    except (OSError, ValueError):
        return False


@contextmanager
def dirlock(path):
    while True:
        try:
            os.mkdir(path)
            break
        except FileExistsError:
            time.sleep(0.2)
    try:
        yield
    finally:
        os.rmdir(path)


def grow(path, gib):
    path.touch()
    if path.stat().st_size < gib * GiB:
        os.truncate(path, gib * GiB)


def human(n):
    for unit in "BKMGT":
        if n < 1024 or unit == "T":
            return f"{n:.0f}{unit}" if unit == "B" or n >= 10 else f"{n:.1f}{unit}"
        n /= 1024


def ensure_key():
    STATE.mkdir(parents=True, exist_ok=True)
    if not KEY.exists():
        subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "vfkit-nix", "-f", str(KEY)], check=True)


def lease_ip(mac, name):
    try:
        text = LEASES.read_text()
    except OSError:
        return ""
    hw = "1," + ":".join(format(int(x, 16), "x") for x in mac.split(":"))  # bootpd drops leading zeros
    by_mac = by_name = ""
    for block in re.findall(r"\{(.*?)\}", text, re.S):
        f = dict(line.strip().split("=", 1) for line in block.splitlines() if "=" in line)
        ip = f.get("ip_address", "")
        if f.get("hw_address") == hw and not by_mac:
            by_mac = ip
        if f.get("name") == name and not by_name:  # clients that send a DUID
            by_name = ip
    return by_mac or by_name


def vfkit_state(sock, state):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(str(sock))
        c = http.client.HTTPConnection("localhost")
        c.sock = s
        c.request("POST", "/vm/state", json.dumps({"state": state}))
        c.getresponse().read()
    except OSError:
        pass


# vfkit boots raw only, and APFS clones need the base on the same volume as the VM disks.
def base_image(img):
    base = STATE / "images" / (Path(img).name.removesuffix(".qcow2") + ".raw")  # name includes the store hash
    if not base.exists():
        base.parent.mkdir(parents=True, exist_ok=True)
        with dirlock(f"{base}.lock"):
            if not base.exists():
                print(f"vf: converting {Path(img).name} to a raw base image (once)...", file=sys.stderr)
                tmp = Path(f"{base}.tmp")
                subprocess.run(["qemu-img", "convert", "-O", "raw", img, tmp], check=True)
                tmp.chmod(0o444)
                tmp.rename(base)
    return base


def ensure_switch(net):
    if not net:
        return
    NET.mkdir(parents=True, exist_ok=True)
    sock, pidfile = NET / f"{net}.sock", NET / f"{net}.pid"
    with dirlock(NET / f"{net}.lock"):
        if not pid_alive(pidfile):
            with open(NET / f"{net}.log", "w") as log:
                p = subprocess.Popen([sys.executable, os.environ["VF_SWITCH"], str(sock)],
                                     stdin=DEVNULL, stdout=log, stderr=STDOUT, start_new_session=True)
            pidfile.write_text(str(p.pid))
            for _ in range(25):
                if sock.is_socket():
                    break
                time.sleep(0.2)
            say(f"started private network '{net}'")
    if not sock.is_socket():
        die(f"private network '{net}' failed to start (see {NET / net}.log)")


MODE = REF = ""
INFO = {}


def find_project():
    if os.environ.get("VF_FILE"):
        return "file", str(Path(os.environ["VF_FILE"]).resolve())
    if os.environ.get("VF_FLAKE"):
        return "flake", os.environ["VF_FLAKE"]
    cwd = Path.cwd()
    for d in [cwd, *cwd.parents]:
        if (d / "vf.nix").is_file():
            return "file", str(d / "vf.nix")
        if (d / "flake.nix").is_file():
            return "flake", str(d)
    die("no vf.nix or flake.nix found (run inside a vfkit-nix project, or set VF_FILE / VF_FLAKE)")


def project_dir():
    if MODE == "file":
        return Path(REF).parent
    p = Path(REF.removeprefix("path:"))
    return p if p.is_dir() else None


def nix_expr():
    return (f'((builtins.getFlake "path:{os.environ["VF_SELF"]}").lib.mkProject (/. + {json.dumps(REF)}))'
            ".legacyPackages.aarch64-darwin")


def load_project():
    global MODE, REF, INFO
    MODE, REF = find_project()
    # exported so per-node child processes (fleet up) skip find + eval
    os.environ["VF_FILE"] = REF if MODE == "file" else ""
    os.environ["VF_FLAKE"] = REF if MODE == "flake" else ""
    if "VF_INFO" not in os.environ:
        args = ["--impure", "--expr", f"{nix_expr()}.vfInfo"] if MODE == "file" else [f"{REF}#vfInfo"]
        r = subprocess.run(["nix", "eval", "--json", *args], stdout=PIPE, text=True)
        if r.returncode:
            die("nix eval failed (see the error above)")
        os.environ["VF_INFO"] = r.stdout
    INFO = json.loads(os.environ["VF_INFO"])


def nix_build(names):
    if MODE == "file":
        args = ["--impure", "--expr", f"map (n: {nix_expr()}.nodes.${{n}}) [ {' '.join(map(json.dumps, names))} ]"]
    else:
        args = [f'{REF}#nodes."{n}"' for n in names]
    r = subprocess.run(["nix", "build", "--no-link", "--print-out-paths", *args], stdout=PIPE, text=True)
    if r.returncode:
        die("nix build failed (see the error above)")
    return r.stdout.split()


def running(name):
    return pid_alive(STATE / name / "vfkit.pid")


def node_ip(name):
    info = INFO["nodes"][name]
    return info["ip"] or lease_ip(info["mac"], name)


def ssh_cmd(name, *cmd, opts=()):
    return [SSH, *SSH_OPTS, *opts, f"{USER}@{node_ip(name)}", *cmd]


def wait_exit(name, secs):
    for _ in range(secs):
        if not running(name):
            return True
        time.sleep(1)
    return not running(name)


def cleanup(name):
    d = STATE / name
    for f in ("vfkit.pid", "vfkit.sock"):
        (d / f).unlink(missing_ok=True)


def up(name):
    info = INFO["nodes"][name]
    d = STATE / name
    if running(name):
        say(f"{name} is already running")
        return True
    built = json.loads(os.environ.get("VF_BUILT", "{}"))
    out = Path(built.get(name) or nix_build([name])[0])
    j = json.loads((out / "node.json").read_text())
    for src in j["mounts"]:
        path = Path(src).expanduser()
        if not path.is_absolute():
            if not project_dir():
                die(f"mount source '{src}' is relative, but the project {REF} is not a local folder")
            path = project_dir() / path
        if not path.is_dir():
            die(f"mount source {path} is not a directory on this Mac")
    (d / "cloud-init").mkdir(parents=True, exist_ok=True)
    ensure_key()

    disk = d / "disk.raw"
    if not disk.exists():
        base = base_image(j["image"])
        if not quiet(["/bin/cp", "-c", base, disk]):  # -c = APFS clone
            shutil.copyfile(base, disk)
        disk.chmod(0o644)
    grow(disk, j["diskGiB"])
    if j["dataGiB"] > 0:
        data = d / "data.raw"
        if not data.exists() or data.stat().st_size == 0:
            say(f"creating {j['dataGiB']}G data disk")
        grow(data, j["dataGiB"])

    pub = Path(f"{KEY}.pub").read_text().strip()
    for f in ("user-data", "meta-data", "network-config"):
        text = (out / "cloud-init" / f).read_text()
        (d / "cloud-init" / f).write_text(text.replace("@VF_USER@", USER).replace("@VF_SSH_PUBKEY@", pub))

    ensure_switch(info["privateNetwork"])

    for f in ("vfkit.sock", "console.log"):
        (d / f).unlink(missing_ok=True)
    with open(d / "vfkit.log", "w") as log:
        vfkit = subprocess.Popen([out / "bin/run", d, NET, project_dir() or ""], stdin=DEVNULL, stdout=log, stderr=STDOUT,
                                 start_new_session=True)
    (d / "vfkit.pid").write_text(str(vfkit.pid))

    say(f"booting {name} ", end="")
    for _ in range(180):
        if vfkit.poll() is not None:
            print()
            sys.stderr.write("".join((d / "vfkit.log").read_text().splitlines(True)[-20:]))
            die(f"vfkit exited (see {d}/vfkit.log)")
        ip = node_ip(name)
        if ip and quiet(ssh_cmd(name, "true", opts=["-o", "BatchMode=yes"])):
            break
        print(".", end="", flush=True)
        time.sleep(1)
    else:
        print()
        die(f"timed out waiting for ssh (see: vf {name} console)")
    print(f" {ip}")

    say("waiting for cloud-init...")
    st = subprocess.run(ssh_cmd(name, "sudo cloud-init status --wait >/dev/null 2>&1; sudo cloud-init status"),
                        stdin=DEVNULL, stdout=PIPE, stderr=DEVNULL, text=True).stdout.strip()
    say(f"cloud-init {st}")
    if "done" not in st:
        print(f"vf: see: vf {name} ssh -- sudo cat /var/log/cloud-init-output.log", file=sys.stderr)
        return False

    timeout = int(os.environ.get("VF_READY_TIMEOUT", 600))
    for check in filter(None, j["ready"]):
        say(f"waiting for: {check}")
        start = time.monotonic()
        while not quiet(ssh_cmd(name, f"sudo sh -c {shlex.quote(check)}")):
            if time.monotonic() - start > timeout:
                print(f"vf: ready check timed out after {timeout}s; see: vf {name} ssh -- sudo journalctl -b -p warning",
                      file=sys.stderr)
                return False
            time.sleep(3)

    say(f"{name} ready ({ip})")
    if j["notes"]:
        print(j["notes"])
    return True


def ssh_into(name, args):
    if not (running(name) and node_ip(name)):
        die(f"{name} is not running (vf {name} up)")
    os.execv(SSH, ssh_cmd(name, *args))


def kill(name):
    d = STATE / name
    if running(name):
        vfkit_state(d / "vfkit.sock", "HardStop")
        if not wait_exit(name, 5):
            try:
                os.kill(int((d / "vfkit.pid").read_text()), signal.SIGTERM)
            except (OSError, ValueError):
                pass
            wait_exit(name, 5)
        say(f"killed {name}")
    cleanup(name)


def stop(name):
    d = STATE / name
    if not running(name):
        say(f"{name} is not running")
        cleanup(name)
        return
    say(f"stopping {name}...")
    if node_ip(name):
        quiet(ssh_cmd(name, "sudo systemctl poweroff"))
    else:
        vfkit_state(d / "vfkit.sock", "Stop")
    if not wait_exit(name, 60):
        say("graceful stop timed out, hard stopping")
        kill(name)
        return
    cleanup(name)
    say(f"stopped {name}")


def destroy(name, args):
    d = STATE / name
    if args not in ([], ["--data"]):
        die(f"unknown option '{args[0]}'")
    data = d / "data.raw"
    wipe = args == ["--data"] or not data.exists()
    if running(name):
        # keeping the data disk: shut down cleanly so the guest flushes it
        kill(name) if wipe else stop(name)
    if wipe:
        shutil.rmtree(d, ignore_errors=True)
        say(f"destroyed {name}")
    else:
        for c in d.iterdir():
            if c.name != "data.raw":
                shutil.rmtree(c) if c.is_dir() else c.unlink()
        say(f"destroyed {name}, kept data disk (use --data to delete it too)")


def header():
    print(ROW.format("NODE", "OS", "STATE", "CPUS", "MEM", "IP", "PRIVATE_IP", "DATA DISK"))


def status_line(name):
    info = INFO["nodes"][name]
    d = STATE / name
    if running(name):
        state, ip = "running", node_ip(name)
    else:
        state, ip = ("stopped" if (d / "disk.raw").exists() else "absent"), info["ip"]
    data = ""
    if (d / "data.raw").exists():
        st = (d / "data.raw").stat()
        data = f"{st.st_size // GiB}G ({human(st.st_blocks * 512)} used)"
    mem = f"{info['memory'] / 1024:g}G"
    print(ROW.format(name, info["os"], state, info["cpus"], mem, ip or "-", info["privateIp"] or "-", data))


def console(name):
    d = STATE / name
    d.mkdir(parents=True, exist_ok=True)
    (d / "console.log").touch()
    os.execv("/usr/bin/tail", ["tail", "-n", "100", "-f", str(d / "console.log")])


def show(name):
    out = Path(nix_build([name])[0])
    print(out)
    for f in ("cloud-init/user-data", "cloud-init/meta-data", "cloud-init/network-config", "bin/run", "node.json"):
        print(f"\n==> {f}")
        print((out / f).read_text(), end="")


def cmd_list():
    header()
    for name in sorted(INFO["nodes"]):
        status_line(name)
    for d in sorted(p for p in STATE.glob("*") if p.is_dir()):
        if d.name not in ("net", "images") and d.name not in INFO["nodes"]:
            print(ROW.format(d.name, "?", "orphan", "", "", "-", "-", f"not in the project: rm -rf {d}"))


FLEET_PARALLEL = ("up", "rebuild", "stop", "kill", "destroy")


def cmd_fleet(fleet, cmd, args):
    nodes = INFO["fleets"].get(fleet)
    if not nodes:
        die(f"no fleet '{fleet}' (fleets: {', '.join(sorted(INFO['fleets']))})")
    if cmd == "status":
        header()
        for name in nodes:
            status_line(name)
        return True
    if cmd == "ssh":
        args = args[1:] if args[:1] == ["--"] else args
        if not args:
            die(f"usage: vf @{fleet} ssh -- <command>")
        ok = True
        for name in nodes:
            print(f"== {name}", flush=True)
            ok = subprocess.run([*SELF, name, cmd, *args]).returncode == 0 and ok
        return ok
    if cmd not in FLEET_PARALLEL:
        die(f"vf @{fleet} {cmd}: not a fleet command (use: {', '.join(FLEET_PARALLEL)}, status, ssh)")

    if cmd in ("up", "rebuild"):
        ensure_key()
        built = {p.split("-vfkit-node-", 1)[1]: p for p in nix_build(nodes)}
        os.environ["VF_BUILT"] = json.dumps(built)

    def prefixed(name, proc):
        for line in proc.stdout:
            print(f"[{name}] {line}", end="", flush=True)

    procs = [(n, subprocess.Popen([*SELF, n, cmd, *args], stdin=DEVNULL, stdout=PIPE, stderr=STDOUT, text=True))
             for n in nodes]
    threads = [threading.Thread(target=prefixed, args=p) for p in procs]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    failed = [n for n, p in procs if p.wait() != 0]
    if failed:
        print(f"vf: @{fleet} {cmd} failed on: {', '.join(failed)}", file=sys.stderr)
        return False
    if cmd in ("up", "rebuild"):
        say(f"@{fleet}: all {len(nodes)} nodes ready")
    return True


def cmd_net(args):
    sub = args[0] if args else "list"
    if sub == "list":
        print(f"{'NETWORK':<16} {'STATE':<8} SOCKET")
        for pidfile in sorted(NET.glob("*.pid")):
            net = pidfile.stem
            if pid_alive(pidfile):
                print(f"{net:<16} {'running':<8} {NET / net}.sock")
            else:
                print(f"{net:<16} {'stopped':<8} -")
    elif sub == "stop" and len(args) == 2:
        net = args[1]
        pidfile = NET / f"{net}.pid"
        if pid_alive(pidfile):
            os.kill(int(pidfile.read_text()), signal.SIGTERM)
        pidfile.unlink(missing_ok=True)
        (NET / f"{net}.sock").unlink(missing_ok=True)
        say(f"stopped private network '{net}'")
    else:
        die("usage: vf net [list | stop <network>]")
    return True


def main(argv):
    if not argv:
        print(USAGE, file=sys.stderr)
        return False
    if argv[0] in ("-h", "--help", "help"):
        print(USAGE)
        return True
    if argv[0] == "net":
        return cmd_net(argv[1:])

    load_project()
    if argv[0] == "list":
        cmd_list()
        return True

    target, cmd, args = argv[0], (argv[1] if len(argv) > 1 else "status"), argv[2:]
    if target.startswith("@"):
        return cmd_fleet(target[1:], cmd, args)

    if target not in INFO["nodes"]:
        die(f"no node '{target}' (nodes: {', '.join(sorted(INFO['nodes']))})")
    if cmd == "up":
        return up(target)
    elif cmd == "ssh":
        ssh_into(target, args)
    elif cmd == "stop":
        stop(target)
    elif cmd == "kill":
        kill(target)
    elif cmd == "status":
        header()
        status_line(target)
    elif cmd == "ip":
        ip = node_ip(target)
        if not ip:
            die(f"{target} has no IP yet (is it running? vf {target} up)")
        print(ip)
    elif cmd == "console":
        console(target)
    elif cmd == "show":
        show(target)
    elif cmd == "destroy":
        destroy(target, args)
    elif cmd == "rebuild":
        destroy(target, args)
        return up(target)
    else:
        print(USAGE, file=sys.stderr)
        return False
    return True


if __name__ == "__main__":
    try:
        sys.exit(0 if main(sys.argv[1:]) else 1)
    except Fail as e:
        print(f"vf: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
