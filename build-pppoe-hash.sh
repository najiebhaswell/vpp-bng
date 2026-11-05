#!/bin/bash
# Builds the kernel pppoe module with 8192 session hash buckets (kernel-patches/0001-pppoe-8192-hash-buckets.patch)
# for the running kernel and installs it to /lib/modules/<version>/updates/, which modprobe prefers. Stock kernels
# have CONFIG_PPPOE_HASH_BITS=4: 16 buckets, so with tens of thousands of sessions every control frame (LCP, CHAP,
# IPCP, PADT) walks thousands of entries in the kernel and the CP tap overflows. Needs the kernel headers.
# Takes effect when the module is reloaded: stop accel-pppd, rmmod pppoe, modprobe pppoe. Undo: remove the file
# from updates/, depmod -a, reload.
set -euo pipefail
cd "$(dirname "$0")"
K=$(uname -r)
V=${KERNEL_TAG:-v$(echo "$K" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')}
D=build/pppoe-hash-$K
rm -rf "$D" && mkdir -p "$D/drivers/net/ppp"
curl -sfL -o "$D/drivers/net/ppp/pppoe.c" \
  "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/net/ppp/pppoe.c?h=$V"
patch -d "$D" -p1 < kernel-patches/0001-pppoe-8192-hash-buckets.patch
printf 'obj-m += pppoe.o\n' > "$D/drivers/net/ppp/Kbuild"
make -C "/lib/modules/$K/build" M="$PWD/$D/drivers/net/ppp" modules
sudo install -D -m 644 "$D/drivers/net/ppp/pppoe.ko" "/lib/modules/$K/updates/pppoe.ko"
sudo depmod -a
echo "installed /lib/modules/$K/updates/pppoe.ko (kernel $V source); reload the module to use it"
