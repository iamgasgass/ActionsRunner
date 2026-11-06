#!/bin/sh
# Eseguito dentro un container alpine (x86_64): crea il rootfs riscv64 di Alpine e l'immagine ext2.
set -eu
: "${ALPINE:=v3.21}"
: "${PKGS:=bash coreutils findutils grep sed gawk diffutils patch tar gzip xz zip unzip file git curl wget jq python3 py3-pip make nodejs npm openssh-client rsync}"
W=/w
R=$W/work/rootfs
REPO=https://dl-cdn.alpinelinux.org/alpine/$ALPINE
apk add --no-cache e2fsprogs >/dev/null
rm -rf "$R" && mkdir -p "$R"
APK="apk --root $R --arch riscv64 --allow-untrusted --no-scripts --no-cache -X $REPO/main -X $REPO/community"
$APK --initdb add alpine-baselayout alpine-baselayout-data busybox busybox-binsh musl apk-tools ca-certificates-bundle
for p in $PKGS; do
  $APK add "$p" >/dev/null 2>&1 && echo "OK   $p" || echo "SKIP $p (non disponibile per riscv64)"
done
install -m 755 $W/scripts/vm/ar-init  "$R/sbin/ar-init"
install -m 755 $W/scripts/vm/ar-agent "$R/sbin/ar-agent"
cp $W/scripts/vm/cmdline.txt "$W/out/vm-cmdline.txt"
mkdir -p "$R/usr/local/bin"
for c in sudo apt-get brew; do install -m 755 "$W/scripts/vm/compat/$c" "$R/usr/local/bin/$c"; done
ln -sf apt-get "$R/usr/local/bin/apt"
printf '%s/main\n%s/community\n' "$REPO" "$REPO" > "$R/etc/apk/repositories"
echo actionsrunner > "$R/etc/hostname"
mkdir -p "$R/home/runner" "$R/mnt/host" "$R/root" "$R/dev" "$R/proc" "$R/sys" "$R/tmp" "$R/run"
# Nodi di dispositivo statici: servono al kernel per aprire la console iniziale di PID 1
# anche se devtmpfs non è disponibile (senza /dev/console init non ha né stdin né stdout).
mkn() { rm -f "$R/dev/$1"; mknod -m "$2" "$R/dev/$1" "$3" "$4" "$5"; }
mkn console 600 c 5 1
mkn tty     666 c 5 0
mkn null    666 c 1 3
mkn zero    666 c 1 5
mkn random  444 c 1 8
mkn urandom 444 c 1 9
mkn hvc0    600 c 229 0
mkn ttyS0   600 c 4 64
chmod 1777 "$R/tmp"
# riepilogo dei pacchetti installati, mostrato dall'app
ls "$R/lib/apk/db" >/dev/null 2>&1 && grep '^P:' "$R/lib/apk/db/installed" | cut -c3- | sort > "$W/out/packages.txt" || true
USED=$(du -sm "$R" | cut -f1)
SIZE=$((USED + 192))
rm -f "$W/out/rootfs.ext2"
mke2fs -q -t ext2 -L rootfs -b 4096 -E root_owner=0:0 -d "$R" "$W/out/rootfs.ext2" "${SIZE}M"
echo "Rootfs: ${USED} MB usati, immagine ${SIZE} MB"
