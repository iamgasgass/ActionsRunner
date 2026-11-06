#!/usr/bin/env python3
"""Avvia la VM con TinyEMU e la collauda con lo stesso protocollo usato dall'app.

uso: vm-boot-test.py <temu> <cfg> <cartella-condivisa>
"""
import os
import queue
import re
import subprocess
import sys
import threading
import time

temu, cfg, shared = sys.argv[1:4]
BOOT_TIMEOUT = int(os.environ.get("BOOT_TIMEOUT", "900"))
STALL_TIMEOUT = int(os.environ.get("STALL_TIMEOUT", "300"))
RUN_TIMEOUT = int(os.environ.get("RUN_TIMEOUT", "900"))
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
summary = []
t0 = time.time()

proc = subprocess.Popen([temu, cfg], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT, bufsize=0)
lines = queue.Queue()


def reader():
    buf = b""
    while True:
        d = os.read(proc.stdout.fileno(), 65536)
        if not d:
            break
        buf += d
        while b"\n" in buf:
            raw, buf = buf.split(b"\n", 1)
            line = ANSI.sub("", raw.decode("utf-8", "replace").rstrip("\r"))
            print(f"[{time.time() - t0:7.1f}s] {line}", flush=True)
            lines.put(line)
    if buf:
        lines.put(buf.decode("utf-8", "replace"))
    lines.put(None)


threading.Thread(target=reader, daemon=True).start()


def fail(msg):
    print(f"::error::{msg}", flush=True)
    summary.append(f"❌ {msg}")
    write_summary()
    try:
        proc.kill()
    except Exception:
        pass
    sys.exit(1)


def write_summary():
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    with open(path, "a") as f:
        f.write("### Collaudo della VM Linux (TinyEMU, stessa configurazione dell'app)\n\n")
        for s in summary:
            f.write(f"- {s}\n")
        f.write("\n")


def wait_for(pred, timeout, what):
    limit = time.time() + timeout
    last = time.time()
    while True:
        now = time.time()
        if now > limit:
            fail(f"{what}: timeout dopo {timeout} s")
        if now - last > STALL_TIMEOUT:
            fail(f"{what}: nessun output dalla VM da {STALL_TIMEOUT} s")
        try:
            line = lines.get(timeout=1)
        except queue.Empty:
            continue
        last = time.time()
        if line is None:
            fail(f"{what}: l'emulatore è terminato (exit {proc.wait()})")
        if line.startswith("__AR_VM_EXIT__") or "Kernel panic" in line:
            fail(f"{what}: {line}")
        r = pred(line)
        if r is not None:
            return r


def send(text):
    proc.stdin.write(text.encode())
    proc.stdin.flush()


# 1. avvio
boot = {}


def boot_pred(line):
    if line.startswith("__AR_BOOT__"):
        for tok in line.split()[1:]:
            k, _, v = tok.partition("=")
            boot[k] = v
    if line.startswith("__AR_READY__"):
        return True
    return None


wait_for(boot_pred, BOOT_TIMEOUT, "avvio della VM")
boot_s = time.time() - t0
summary.append(f"✅ VM pronta in {boot_s:.1f} s (kernel {boot.get('kernel', '?')}, 9p={boot.get('9p')}, rete={boot.get('net')})")
if boot.get("9p") != "1":
    fail("cartella condivisa virtio-9p non montata nella VM")


def run(name, script, timeout=RUN_TIMEOUT):
    d = os.path.join(shared, "vm-test")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, name + ".sh"), "w") as f:
        f.write("#!/bin/sh\n" + script + "\n")
    out = []
    t = time.time()
    send(f"__AR_RUN__ {name} /mnt/host/vm-test/{name}.sh\n")

    def pred(line):
        if line.startswith(f"__AR_DONE__ {name} "):
            return int(line.split()[-1])
        out.append(line)
        return None

    rc = wait_for(pred, timeout, f"comando {name}")
    return rc, out, time.time() - t


# 2. controlli essenziali (devono passare)
rc, out, dt = run("core", r"""
set -e
uname -a
cat /etc/alpine-release
echo "PATH=$PATH"
mkdir -p /mnt/host/job
echo from-guest > /mnt/host/job/from-guest.txt
mount --bind /mnt/host/job /home/runner
cat /home/runner/from-guest.txt
umount /home/runner
bash --noprofile --norc -eo pipefail -c 'echo "bash $BASH_VERSION"; set -u; a=(); echo "${#a[@]}"'
git --version
python3 -c 'import sys, json, hashlib; print("python", sys.version.split()[0])'
cd /tmp && rm -rf r && git init -q r && cd r && git config user.email a@b.c && git config user.name t \
  && echo x > f && git add f && git commit -qm init && git log --oneline | head -1
echo CORE_OK
""")
if rc != 0 or "CORE_OK" not in out:
    fail(f"controlli essenziali falliti (exit {rc})")
host_file = os.path.join(shared, "job", "from-guest.txt")
if not os.path.exists(host_file) or open(host_file).read().strip() != "from-guest":
    fail("il file scritto dalla VM non è visibile nella cartella condivisa dell'host")
summary.append(f"✅ shell, bash, git, python3, 9p e bind mount ({dt:.1f} s)")

# 3. controlli facoltativi (avvisi)
for name, script in [
    ("node", "node -e 'console.log(\"node\", process.version)' && npm --version"),
    ("rete", "wget -q -O /dev/null http://dl-cdn.alpinelinux.org/alpine/ && echo http-ok && curl -fsS -o /dev/null https://github.com && echo https-ok"),
    ("tools", "for c in curl jq make tar gzip xz zip unzip rsync ssh sudo apt-get; do command -v $c >/dev/null && echo \"ok $c\" || echo \"MANCA $c\"; done"),
]:
    rc, out, dt = run(name, script)
    if rc == 0:
        summary.append(f"✅ {name} ({dt:.1f} s)")
    else:
        print(f"::warning::controllo {name} non riuscito (exit {rc})", flush=True)
        summary.append(f"⚠️ {name}: exit {rc} — {' | '.join(out[-3:])}")

write_summary()
proc.kill()
print(f"Collaudo della VM superato (avvio {boot_s:.1f} s)")
