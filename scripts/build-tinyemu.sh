#!/usr/bin/env bash
# Compila TinyEMU (emulatore RISC-V di Fabrice Bellard, licenza MIT) come libreria statica per iOS arm64.
#
# Sorgente principale: fork fernandotcl/TinyEMU, che supporta ufficialmente macOS e iOS
#   (temu_main al posto di main, OSByteOrder, statfs/st_atimespec di Darwin).
# Ripiego automatico: tarball originale di Bellard con gli adattamenti in scripts/tinyemu-ios.
#
# Uscita: Vendor/LinuxVM/libtemu.a  (+ Vendor/LinuxVM/BUILD_INFO.txt)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Vendor/LinuxVM"
WORK="$ROOT/work/tinyemu"
FORK_URL="${TINYEMU_FORK_URL:-https://github.com/fernandotcl/TinyEMU.git}"
FORK_REF="${TINYEMU_FORK_REF:-master}"
BELLARD_VER="2019-12-21"
MIN_IOS="17.0"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"
AR="$(xcrun --sdk iphoneos -f ar)"
NM="$(xcrun --sdk iphoneos -f nm)"

mkdir -p "$OUT" "$WORK"
rm -f "$OUT/libtemu.a" "$OUT/BUILD_INFO.txt"

COMMON_FLAGS=(-arch arm64 -isysroot "$SDK" -miphoneos-version-min="$MIN_IOS"
  -O2 -g0 -fno-strict-aliasing -fvisibility=default
  -Wno-everything -Wno-error=implicit-function-declaration -Wno-error=implicit-int
  -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -D_GNU_SOURCE
  -DCONFIG_SLIRP -DCONFIG_RISCV_MAX_XLEN=64)

# File da compilare (quelli assenti in una delle due varianti vengono saltati).
CORE_FILES=(virtio pci fs cutils iomem simplefb json machine temu elf fs_disk riscv_machine softfp)
SLIRP_FILES=(bootp ip_icmp mbuf slirp tcp_output cksum ip_input misc socket tcp_subr udp if ip_output sbuf tcp_input tcp_timer)

# Prova di collegamento: un eseguibile iOS che usa temu_main deve linkare senza simboli mancanti.
link_check() {
  local lib=$1 dir=$2
  cat > "$dir/linkcheck.c" <<'C'
extern int temu_main(int, char **);
void console_get_size(void *opaque, int *pw, int *ph) { (void)opaque; *pw = 120; *ph = 40; }
int main(int argc, char **argv) { return argc > 99 ? temu_main(argc, argv) : 0; }
C
  "$CC" -arch arm64 -isysroot "$SDK" -miphoneos-version-min="$MIN_IOS" "$dir/linkcheck.c" \
    -Wl,-force_load,"$lib" -lresolv -lz -o "$dir/linkcheck" 2> "$dir/link.log"
}

# $1 = nome variante, $2 = cartella sorgenti, $3.. = flag extra
build_variant() {
  local variant=$1 src=$2; shift 2
  # bash 3.2 di macOS: un array vuoto con "set -u" è "unbound", quindi si espande con ${a[@]+...}
  local extra=()
  if [ $# -gt 0 ]; then extra=("$@"); fi
  local objdir="$src/ios-obj"
  rm -rf "$objdir" && mkdir -p "$objdir"
  cp "$ROOT/scripts/tinyemu-ios/compat.h" "$ROOT/scripts/tinyemu-ios/compat.c" "$src/"
  rm -rf "$src/ios-stubs" && cp -R "$ROOT/scripts/tinyemu-ios/stubs" "$src/ios-stubs"
  local flags=("${COMMON_FLAGS[@]}" "-DCONFIG_VERSION=\"$(cat "$src/VERSION" 2>/dev/null || echo "$variant")\""
               -I"$src" -I"$src/ios-stubs" -include "$src/compat.h" ${extra[@]+"${extra[@]}"})
  local objs=()
  local f
  echo "=== Variante: $variant ($src)"
  for f in "${CORE_FILES[@]}" compat; do
    [ -f "$src/$f.c" ] || { echo "  (assente) $f.c"; continue; }
    echo "  CC $f.c"
    "$CC" "${flags[@]}" -c "$src/$f.c" -o "$objdir/$f.o" || return 1
    objs+=("$objdir/$f.o")
  done
  for x in 32 64; do
    echo "  CC riscv_cpu.c (MAX_XLEN=$x)"
    "$CC" "${flags[@]}" -DMAX_XLEN=$x -c "$src/riscv_cpu.c" -o "$objdir/riscv_cpu$x.o" || return 1
    objs+=("$objdir/riscv_cpu$x.o")
  done
  for f in "${SLIRP_FILES[@]}"; do
    echo "  CC slirp/$f.c"
    "$CC" "${flags[@]}" -I"$src/slirp" -c "$src/slirp/$f.c" -o "$objdir/slirp_$f.o" || return 1
    objs+=("$objdir/slirp_$f.o")
  done
  local lib="$objdir/libtemu.a"
  rm -f "$lib"
  [ ${#objs[@]} -gt 0 ] || { echo "  nessun oggetto compilato"; return 1; }
  "$AR" rcs "$lib" "${objs[@]}"
  # (niente "nm | grep -q": con pipefail il SIGPIPE di nm darebbe un falso negativo)
  "$NM" -g "$objdir/temu.o" > "$objdir/temu.syms" 2>/dev/null || true
  if ! grep -q " T _temu_main$" "$objdir/temu.syms"; then
    if grep -q " T _main$" "$objdir/temu.syms"; then
      echo "  temu.c esporta main: ricompilo con -Dmain=temu_main"
      "$CC" "${flags[@]}" -Dmain=temu_main -c "$src/temu.c" -o "$objdir/temu.o" || return 1
      rm -f "$lib"
      "$AR" rcs "$lib" "${objs[@]}"
      "$NM" -g "$objdir/temu.o" > "$objdir/temu.syms" 2>/dev/null || true
    fi
  fi
  if ! grep -q " T _temu_main$" "$objdir/temu.syms"; then
    echo "  temu_main non trovato. Simboli globali di temu.o:"
    grep " T " "$objdir/temu.syms" | head -20
    return 1
  fi
  echo "  temu_main esportato"
  if ! link_check "$lib" "$objdir"; then
    echo "  Simboli non risolti:"; grep -E "Undefined|_[a-zA-Z0-9_]+, referenced|\"_" "$objdir/link.log" | head -40 || cat "$objdir/link.log"
    return 1
  fi
  cp "$lib" "$OUT/libtemu.a"
  {
    echo "variante: $variant"
    echo "sorgente: $src"
    [ -d "$src/.git" ] && echo "commit: $(git -C "$src" rev-parse HEAD)"
    echo "sdk: $SDK"
    echo "oggetti: ${#objs[@]}"
  } > "$OUT/BUILD_INFO.txt"
  echo "=== libtemu.a pronto ($variant)"
  return 0
}

# --- 1. fork con supporto iOS ---
FORK_DIR="$WORK/fork"
rm -rf "$FORK_DIR"
if git clone --depth 1 --branch "$FORK_REF" "$FORK_URL" "$FORK_DIR" 2>&1 | tail -2; [ -f "$FORK_DIR/temu.c" ]; then
  if build_variant "fernandotcl/TinyEMU@$FORK_REF" "$FORK_DIR"; then
    cat "$OUT/BUILD_INFO.txt"; exit 0
  fi
  echo "::warning::Compilazione del fork TinyEMU non riuscita, provo il sorgente originale"
fi

# --- 2. sorgente originale di Bellard (main rinominato in temu_main) ---
BDIR="$WORK/tinyemu-$BELLARD_VER"
rm -rf "$BDIR"
curl -fsSL "https://bellard.org/tinyemu/tinyemu-$BELLARD_VER.tar.gz" -o "$WORK/tinyemu.tar.gz"
tar xzf "$WORK/tinyemu.tar.gz" -C "$WORK"
if build_variant "bellard-$BELLARD_VER" "$BDIR" -Dmain=temu_main; then
  cat "$OUT/BUILD_INFO.txt"; exit 0
fi

echo "::error::Impossibile compilare TinyEMU per iOS (vedi log sopra)"
exit 1
