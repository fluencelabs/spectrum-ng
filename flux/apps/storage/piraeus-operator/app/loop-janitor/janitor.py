#!/usr/bin/env python3
"""Report — and, if asked, detach — loop devices kubelet leaked on block PVs.

Default is observe only (DRY_RUN=1 on the DaemonSet): leaked loops show up
as loop_janitor_stale_loops and the DrbdLeakedLoopDevices alert; a human
detaches them. DRY_RUN=0 makes the sweep losetup -d them itself.

kubelet losetup's every block volume it maps (a keep-open "fd lock" on
.../volumeDevices/<pv>/dev/<podUID>) and looks the loop up by that path on
unmap. Once the bind mount is gone the backing shows as "/" and the lookup
fails silently, so the loop stays and keeps the DRBD device open. LINSTOR then
cannot `drbdadm down` the device when the PVC is deleted, peers drop their
replicas, and the survivor is a peerless Primary with quorum:no — the
DrbdQuorumLost incident of 2026-09-12 on poz-bey-c01 (9 orphans, 49 leaked
loops across three nodes).

A loop is stale when its backing path is gone AND the backing inode is a
/dev/drbd* device node AND nothing stacks on it (/sys/block/loopN/holders is
empty) AND no mount in the host namespace uses it. The inode test is what
keeps this away from Talos' own loops — rootfs.sqsh, modules.dep.sqsh and the
extension squashfs images also show a "(deleted)" backing but are regular
files, not DRBD nodes. A stale loop by this definition is unreachable by
anything, so detaching is safe; a detach that still fails means something we
do not model holds it, and that is exported as a failure for the alert.
"""

import http.server
import json
import os
import subprocess
import threading
import time

INTERVAL = int(os.environ.get("INTERVAL_SECONDS", "300"))
PORT = int(os.environ.get("METRICS_PORT", "9943"))
DRY_RUN = os.environ.get("DRY_RUN", "") == "1"
NODE = os.environ.get("NODE_NAME", "unknown")

state = {"stale": 0, "detached_total": 0, "failed": 0, "last_run": 0.0}


def host_mounted_sources():
    with open("/proc/1/mountinfo") as f:
        return {line.split()[9] for line in f if len(line.split()) > 9}


def drbd_node_inodes():
    """inode -> /dev/drbdNNNN for every DRBD device node on the host."""
    return {
        e.inode(): e.path
        for e in os.scandir("/dev")
        if e.name.startswith("drbd") and e.name[4:].isdigit()
    }


def stale_loops():
    out = subprocess.run(
        ["losetup", "-l", "-n", "-J", "-O", "NAME,BACK-INO,BACK-FILE"],
        capture_output=True, text=True, check=True,
    ).stdout
    mounted = host_mounted_sources()
    drbd = drbd_node_inodes()
    for dev in json.loads(out or '{"loopdevices":[]}')["loopdevices"]:
        name, back = dev["name"], dev["back-file"] or ""
        if not (back == "/" or back.endswith("(deleted)")):
            continue
        target = drbd.get(int(dev["back-ino"]))
        if target is None:
            continue
        if os.listdir(f"/sys/block/{os.path.basename(name)}/holders"):
            continue
        if name in mounted:
            continue
        yield name, f"{back} -> {target}"


def sweep():
    found = detached = failed = 0
    for name, back in stale_loops():
        found += 1
        if DRY_RUN:
            print(f"stale {name} backing={back!r} (dry run)", flush=True)
            continue
        r = subprocess.run(["losetup", "-d", name], capture_output=True, text=True)
        if r.returncode == 0:
            detached += 1
            print(f"detached {name} backing={back!r}", flush=True)
        else:
            failed += 1
            print(f"FAILED {name} backing={back!r}: {r.stderr.strip()}", flush=True)
    state["stale"] = found
    state["failed"] = failed
    state["detached_total"] += detached
    state["last_run"] = time.time()


class Metrics(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        lbl = f'{{node="{NODE}"}}'
        body = (
            "# HELP loop_janitor_stale_loops Leaked loop devices seen on the last sweep (before detaching).\n"
            "# TYPE loop_janitor_stale_loops gauge\n"
            f"loop_janitor_stale_loops{lbl} {state['stale']}\n"
            "# HELP loop_janitor_detach_failures Stale loops the last sweep could not detach.\n"
            "# TYPE loop_janitor_detach_failures gauge\n"
            f"loop_janitor_detach_failures{lbl} {state['failed']}\n"
            "# HELP loop_janitor_detached_total Loop devices detached since the janitor started.\n"
            "# TYPE loop_janitor_detached_total counter\n"
            f"loop_janitor_detached_total{lbl} {state['detached_total']}\n"
            "# HELP loop_janitor_last_sweep_timestamp_seconds Unix time of the last completed sweep.\n"
            "# TYPE loop_janitor_last_sweep_timestamp_seconds gauge\n"
            f"loop_janitor_last_sweep_timestamp_seconds{lbl} {state['last_run']}\n"
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def main():
    srv = http.server.ThreadingHTTPServer(("", PORT), Metrics)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    while True:
        try:
            sweep()
        except Exception as e:  # keep serving metrics; a broken sweep shows as a stale timestamp
            print(f"sweep failed: {e}", flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
