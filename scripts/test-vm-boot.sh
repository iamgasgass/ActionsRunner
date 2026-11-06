#!/usr/bin/env bash
# Collaudo dell'immagine Linux PRIMA che entri nell'IPA.
# Compila TinyEMU (stesso sorgente usato per iOS) per il runner Linux e avvia la VM con la stessa
# configurazione dell'app: stessi bbl64.bin, kernel, rootfs, riga di comando del kernel,
# cartella condivisa virtio-9p "hostfs" e rete slirp. Poi esegue i comandi tramite il protocollo
# __AR_RUN__/__AR_DONE__ dell'agente, esattamente come fa l'app.
#
# Se la VM non arriva a __AR_READY__ o i controlli essenziali falliscono, lo script esce con errore
# e l'immagine non viene pubblicata (quindi non finisce in un IPA che resterebbe bloccato all'avvio).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUTDIR="$ROOT/out"
W="$ROOT/work/vmtest"
FORK_URL="${TINYEMU_FORK_URL:-https://github.com/fernandotcl/TinyEMU.git}"
FORK_REF="${TINYEMU_FORK_REF:-master}"
MEM="${VM_MEMORY_MB:-512}"

for f in bbl64.bin kernel-riscv64.bin rootfs.ext2 vm-cmdline.txt; do
  test -f "$OUTDIR/$f" || { echo "::error::manca out/$f"; exit 1; }
done

rm -rf "$W" && mkdir -p "$W/obj" "$W/shared"
SRC="$W/src"
if ! git clone -q --depth 1 --branch "$FORK_REF" "$FORK_URL" "$SRC"; then
  curl -fsSL https://bellard.org/tinyemu/tinyemu-2019-12-21.tar.gz | tar xz -C "$W"
  SRC="$W/tinyemu-2019-12-21"
fi

CFLAGS=(-O2 -g0 -fno-strict-aliasing -w -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -D_GNU_SOURCE
        -DCONFIG_SLIRP -DCONFIG_RISCV_MAX_XLEN=64 "-DCONFIG_VERSION=\"ar-test\"" -I"$SRC" -I"$SRC/slirp")
objs=()
for f in virtio pci fs cutils iomem simplefb json machine temu elf fs_disk riscv_machine softfp; do
  [ -f "$SRC/$f.c" ] || continue
  gcc "${CFLAGS[@]}" -c "$SRC/$f.c" -o "$W/obj/$f.o"; objs+=("$W/obj/$f.o")
done
for x in 32 64; do
  gcc "${CFLAGS[@]}" -DMAX_XLEN=$x -c "$SRC/riscv_cpu.c" -o "$W/obj/riscv_cpu$x.o"; objs+=("$W/obj/riscv_cpu$x.o")
done
for f in bootp ip_icmp mbuf slirp tcp_output cksum ip_input misc socket tcp_subr udp if ip_output sbuf tcp_input tcp_timer; do
  gcc "${CFLAGS[@]}" -c "$SRC/slirp/$f.c" -o "$W/obj/slirp_$f.o"; objs+=("$W/obj/slirp_$f.o")
done
gcc -o "$W/temu" "${objs[@]}" -lm -lrt -lpthread
echo "TinyEMU di collaudo compilato: $W/temu"

CMDLINE="$(head -1 "$OUTDIR/vm-cmdline.txt")"
cat > "$W/riscv64.cfg" <<EOF
{
    version: 1,
    machine: "riscv64",
    memory_size: $MEM,
    bios: "$OUTDIR/bbl64.bin",
    kernel: "$OUTDIR/kernel-riscv64.bin",
    cmdline: "$CMDLINE",
    drive0: { file: "$OUTDIR/rootfs.ext2" },
    fs0: { tag: "hostfs", file: "$W/shared" },
    eth0: { driver: "user" },
}
EOF
cat "$W/riscv64.cfg"

python3 "$ROOT/scripts/vm-boot-test.py" "$W/temu" "$W/riscv64.cfg" "$W/shared"
