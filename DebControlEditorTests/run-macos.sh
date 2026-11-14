#!/bin/sh
set -eu
cd "$(dirname "$0")"
command -v zstd >/dev/null || brew install zstd
python3 fixtures.py
rm -rf /tmp/repopocket-deb-control-tests
mkdir /tmp/repopocket-deb-control-tests
for src in ../Vendor/DebCodecs/DebCodecs.c ../Vendor/DebCodecs/xz/*.c ../Vendor/DebCodecs/zstd/zstddeclib.c; do
    clang -O2 -DXZ_USE_CRC64 -DXZ_USE_SHA256 -I../Vendor/DebCodecs/xz -c "$src" -o "/tmp/repopocket-deb-control-tests/$(basename "$src").o"
done
swiftc -import-objc-header ../Vendor/DebCodecs/DebCodecs.h /tmp/repopocket-deb-control-tests/*.o -o /tmp/repopocket-deb-control-tests/harness ../RepoPocket/DebControlEditor.swift Harness.swift -lz
/tmp/repopocket-deb-control-tests/harness fixtures /tmp/repopocket-deb-control-tests
python3 fixtures.py /tmp/repopocket-deb-control-tests
# dpkg-deb optional on macOS; independent stdlib verification above is mandatory.
if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb --info /tmp/repopocket-deb-control-tests/gzip-edited.deb >/dev/null
    dpkg-deb --info /tmp/repopocket-deb-control-tests/plain-edited.deb >/dev/null
fi
