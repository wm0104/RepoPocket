#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
platform=${1:-iphoneos}
case "$platform" in macosx|iphoneos|iphonesimulator) ;; *) echo 'Unsupported Git build platform' >&2; exit 2;; esac
revision=49e408b3208bc3093757a1c2db938d3590f3f412
digest=173c45822177d73bb1a97555d864ad04a3e0486eb0bc3455443a4669a35d8aa2
root="$PWD/NativeBuild"
mkdir -p "$root/source"
archive="$root/source/libgit2-1.9.7.tar.gz"
if [ ! -f "$archive" ]; then
  curl --fail --location --retry 3 "https://codeload.github.com/libgit2/libgit2/tar.gz/$revision" -o "$archive"
fi
echo "$digest  $archive" | shasum -a 256 --check
source="$root/source/libgit2-$revision"
if [ ! -d "$source" ]; then tar -xzf "$archive" -C "$root/source"; fi
options=(-DCMAKE_POLICY_VERSION_MINIMUM=3.5)
if [ "$platform" != macosx ]; then
  options+=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 -DCMAKE_OSX_ARCHITECTURES=arm64)
fi
cmake -S "$source" -B "$root/build-$platform" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$platform" --show-sdk-path)" \
  -DCMAKE_INSTALL_PREFIX="$root/$platform" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DBUILD_EXAMPLES=OFF \
  -DUSE_HTTPS=SecureTransport -DUSE_SSH=OFF -DUSE_GSSAPI=OFF -DUSE_NTLMCLIENT=OFF \
  -DREGEX_BACKEND=builtin -DUSE_SHA256=Builtin "${options[@]}"
cmake --build "$root/build-$platform" --parallel 3
cmake --install "$root/build-$platform"
