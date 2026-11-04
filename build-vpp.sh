#!/bin/bash
# Builds VPP 26.10 (commit 5db7b9abb) + PPPoE patches into .debs. Does not install them.
set -euxo pipefail
cd "$(dirname "$0")"
[ -d vpp ] || git clone --filter=blob:none https://github.com/FDio/vpp.git vpp
cd vpp
git checkout -B bng-2610 5db7b9abb
git -c user.name=vpp-bng -c user.email=vpp-bng@localhost am ../vpp-patches/*.patch
make UNATTENDED=yes install-dep
make UNATTENDED=yes install-ext-deps
make UNATTENDED=yes pkg-deb
ls -la build-root/*.deb
