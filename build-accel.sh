#!/bin/bash
# Builds and installs accel-ppp-ng with the VPP hooks from the fork branch that carries the fixes for VPP 26.10
# (https://github.com/najiebhaswell/accel-ppp-ng, branch vpp-2610-fixes). Installs to /usr/local; needs the
# patched VPP dev packages (vpp-dev, libvppinfra-dev) installed first.
set -euxo pipefail
cd "$(dirname "$0")"
REPO=${ACCEL_REPO:-https://github.com/najiebhaswell/accel-ppp-ng.git}
BRANCH=${ACCEL_BRANCH:-vpp-2610-fixes}
[ -d accel-ppp-ng ] || git clone "$REPO" accel-ppp-ng
cd accel-ppp-ng
git fetch "$REPO" "$BRANCH"
git checkout -B "$BRANCH" FETCH_HEAD
mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_DRIVER=FALSE \
  -DRADIUS=TRUE -DSHAPER=TRUE -DNETSNMP=FALSE -DLOG_PGSQL=FALSE -DHAVE_VPP=TRUE -DHAVE_SESSION_HOOKS=TRUE ..
make -j"$(nproc)"
sudo make install
