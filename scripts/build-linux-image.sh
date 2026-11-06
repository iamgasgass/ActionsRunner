#!/usr/bin/env bash
# Prepara kernel, firmware (bbl) e rootfs Alpine riscv64 per la VM integrata nell'app.
# Uscita: out/bbl64.bin, out/kernel-riscv64.bin, out/rootfs.ext2, out/packages.txt
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p out work
DISK=diskimage-linux-riscv-2018-09-23
curl -fsSL "https://bellard.org/tinyemu/$DISK.tar.gz" -o "work/$DISK.tar.gz"
tar xzf "work/$DISK.tar.gz" -C work
cp "$(find work -name bbl64.bin | head -1)" out/bbl64.bin
cp "$(find work -name kernel-riscv64.bin | head -1)" out/kernel-riscv64.bin
docker run --rm -v "$PWD:/w" -e ALPINE="${ALPINE:-v3.21}" ${PKGS:+-e PKGS="$PKGS"} alpine:3.21 sh /w/scripts/linux-rootfs.sh
ls -lh out
