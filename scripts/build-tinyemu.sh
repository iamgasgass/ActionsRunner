#!/usr/bin/env bash
# Compila TinyEMU (emulatore RISC-V di Fabrice Bellard, licenza MIT) come libreria statica per iOS.
# Uscita: Vendor/LinuxVM/libtemu.a (esporta temu_main, usato da ARVMBridge.c)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VER=2019-12-21
OUT="$ROOT/Vendor/LinuxVM"
WORK="$ROOT/work/tinyemu"
mkdir -p "$OUT" "$WORK"
cd "$WORK"
curl -fsSL "https://bellard.org/tinyemu/tinyemu-$VER.tar.gz" -o tinyemu.tar.gz
rm -rf "tinyemu-$VER" && tar xzf tinyemu.tar.gz
cd "tinyemu-$VER"
cp "$ROOT/scripts/tinyemu-ios/compat.h" "$ROOT/scripts/tinyemu-ios/compat.c" .
cp -R "$ROOT/scripts/tinyemu-ios/stubs" .
# Darwin non ha f_namelen in struct statfs
sed -i '' 's/\.f_namelen/.f_bsize*0+255/g' fs_disk.c || true

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"
CFLAGS=(-arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2 -fno-strict-aliasing
        -Wno-everything -Wno-error=implicit-function-declaration
        -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -D_GNU_SOURCE
        "-DCONFIG_VERSION=\"$VER\"" -DCONFIG_SLIRP -DCONFIG_RISCV_MAX_XLEN=64
        -Dmain=temu_main -Istubs -I. -include compat.h)
OBJS=()
build() { local src=$1 obj=$2; shift 2; echo "CC $src"; "$CC" "${CFLAGS[@]}" "$@" -c "$src" -o "$obj"; OBJS+=("$obj"); }
for f in virtio pci fs cutils iomem simplefb json machine temu fs_disk riscv_machine softfp compat; do
  build "$f.c" "$f.o"
done
build riscv_cpu.c riscv_cpu32.o -DMAX_XLEN=32
build riscv_cpu.c riscv_cpu64.o -DMAX_XLEN=64
for f in bootp ip_icmp mbuf slirp tcp_output cksum ip_input misc socket tcp_subr udp if ip_output sbuf tcp_input tcp_timer; do
  build "slirp/$f.c" "slirp_$f.o"
done
rm -f "$OUT/libtemu.a"
ar rcs "$OUT/libtemu.a" "${OBJS[@]}"
nm "$OUT/libtemu.a" | grep -q " T _temu_main" || { echo "temu_main non trovato"; rm -f "$OUT/libtemu.a"; exit 1; }

# Verifica di collegamento: nessun simbolo mancante per iOS
cat > linkcheck.c <<'C'
extern int temu_main(int, char **);
int main(void) { return temu_main ? 0 : 1; }
C
if ! "$CC" -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 linkcheck.c -Wl,-force_load,"$OUT/libtemu.a" -o linkcheck 2> link.log; then
  cat link.log
  echo "::error::libtemu.a ha simboli non risolti su iOS: la VM non verrà inclusa"
  rm -f "$OUT/libtemu.a"
  exit 1
fi
echo "libtemu.a pronto: $OUT/libtemu.a"
