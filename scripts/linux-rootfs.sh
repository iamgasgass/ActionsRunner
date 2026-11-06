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
printf '%s/main\n%s/community\n' "$REPO" "$REPO" > "$R/etc/apk/repositories"
echo actionsrunner > "$R/etc/hostname"
mkdir -p "$R/home/runner" "$R/mnt/host" "$R/root"
# riepilogo dei pacchetti installati, mostrato dall'app
ls "$R/lib/apk/db" >/dev/null 2>&1 && grep '^P:' "$R/lib/apk/db/installed" | cut -c3- | sort > "$W/out/packages.txt" || true
USED=$(du -sm "$R" | cut -f1)
SIZE=$((USED + 192))
rm -f "$W/out/rootfs.ext2"
mke2fs -q -t ext2 -L rootfs -b 4096 -E root_owner=0:0 -d "$R" "$W/out/rootfs.ext2" "${SIZE}M"
echo "Rootfs: ${USED} MB usati, immagine ${SIZE} MB"
