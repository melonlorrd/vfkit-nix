"""vf-switch: a user-mode L2 learning switch for vfkit VMs.

vfkit's `virtio-net,unixSocketPath=<sock>` sends each Ethernet frame as one datagram to <sock>.
No root and no host interface: only the attached VMs see this network.

usage: python3 vf-switch.py <socket-path>
"""
import errno
import os
import socket
import sys


def main() -> None:
    path = sys.argv[1]
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass

    s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
    s.bind(path)
    print(f"vf-switch: listening on {path}", flush=True)

    macs: dict[bytes, str] = {}  # source MAC -> peer socket path
    peers: set[str] = set()

    def send(frame: bytes, peer: str) -> None:
        try:
            s.sendto(frame, peer)
        except OSError as e:
            if e.errno in (errno.ENOENT, errno.ECONNREFUSED):  # VM went away
                peers.discard(peer)
                for m in [m for m, p in macs.items() if p == peer]:
                    del macs[m]
            # ENOBUFS etc.: drop the frame, like a real switch under load

    while True:
        data, peer = s.recvfrom(65536)
        if not peer:
            continue
        if peer not in peers:
            peers.add(peer)
            print(f"vf-switch: peer joined {peer}", flush=True)
        if len(data) < 14:  # "VFKT" handshake or junk
            continue
        dst, src = data[0:6], data[6:12]
        macs[src] = peer
        if dst[0] & 1 or dst not in macs:  # broadcast / multicast / unknown -> flood
            for p in list(peers):
                if p != peer:
                    send(data, p)
        elif macs[dst] != peer:
            send(data, macs[dst])


if __name__ == "__main__":
    main()
