#!/usr/bin/env bash
set -euo pipefail

VERSION="4.7.0"
RE_COMMIT="9bbd795964f48c5624587cf8e8474d92c8ed0033"
BARESIP_COMMIT="bf6cf020b7a173e1b3e31166e8cc5d7f6165df90"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="${RUNNER_TEMP:-$PROJECT_DIR/.build}/baresip-$VERSION"
OUTPUT_DIR="$PROJECT_DIR/Vendor"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/src" "$OUTPUT_DIR"

git clone --depth 1 --branch "v$VERSION" https://github.com/baresip/re.git "$WORK_DIR/src/re"
git clone --depth 1 --branch "v$VERSION" https://github.com/baresip/baresip.git "$WORK_DIR/src/baresip"
test "$(git -C "$WORK_DIR/src/re" rev-parse HEAD)" = "$RE_COMMIT"
test "$(git -C "$WORK_DIR/src/baresip" rev-parse HEAD)" = "$BARESIP_COMMIT"

# Upstream configures excluded test targets that hard-require host OpenSSL even
# for an iOS build using libre's Apple crypto implementation.
sed -i.bak 's/^add_subdirectory(test EXCLUDE_FROM_ALL)$/# iOS XCFramework: tests disabled/' \
  "$WORK_DIR/src/re/CMakeLists.txt"
python3 - "$WORK_DIR/src/baresip/CMakeLists.txt" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
needle = "install(TARGETS baresip_exe baresip\n"
replacement = needle + "  BUNDLE\n    DESTINATION ${CMAKE_INSTALL_BINDIR}\n    COMPONENT Applications\n"
if source.count(needle) != 1:
    raise SystemExit("unexpected Baresip install block")
path.write_text(source.replace(needle, replacement))
PY

build_slice() {
  local name="$1"
  local sdk="$2"
  local re_build="$WORK_DIR/build-re-$name"
  local re_install="$WORK_DIR/install-re-$name"
  local baresip_build="$WORK_DIR/build-baresip-$name"
  local combined="$WORK_DIR/libCRMPhoneBaresip-$name.a"

  cmake -S "$WORK_DIR/src/re" -B "$re_build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.5 \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DUSE_OPENSSL=OFF \
    -DOPENSSL_INCLUDE_DIR="$WORK_DIR/src/re/include" \
    -DLIBRE_BUILD_SHARED=OFF \
    -DLIBRE_BUILD_STATIC=ON \
    -DCMAKE_INSTALL_PREFIX="$re_install"
  cmake --build "$re_build" --config Release --target re --parallel
  cmake --install "$re_build" --config Release

  cmake -S "$WORK_DIR/src/baresip" -B "$baresip_build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.5 \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DSTATIC=ON \
    -DOPENSSL_INCLUDE_DIR="$WORK_DIR/src/re/include" \
    -DCMAKE_PREFIX_PATH="$re_install" \
    -Dre_DIR="$re_install/lib/cmake/re" \
    -DRE_INCLUDE_DIR="$re_install/include/re" \
    -DRE_LIBRARY="$re_install/lib/libre.a" \
    -DMODULES="g711;audiounit;stun;turn;ice"
  cmake --build "$baresip_build" --config Release --target baresip --parallel

  local re_archive
  local baresip_archive
  re_archive="$(find "$re_build" -name 'libre.a' -type f -print -quit)"
  baresip_archive="$(find "$baresip_build" -name 'libbaresip.a' -type f -print -quit)"
  local module_objects=()
  while IFS= read -r object; do
    module_objects+=("$object")
  done < <(find "$baresip_build/modules" -path '*/CMakeFiles/*.dir/*' -name '*.o' -type f | sort)
  if [[ -z "$re_archive" || -z "$baresip_archive" || ${#module_objects[@]} -eq 0 ]]; then
    echo "Missing SIP archives or static module objects for $name" >&2
    exit 1
  fi
  libtool -static -o "$combined" "$re_archive" "$baresip_archive" "${module_objects[@]}"
}

build_slice device iphoneos
build_slice simulator iphonesimulator

HEADERS="$WORK_DIR/headers"
mkdir -p "$HEADERS"
cp "$WORK_DIR/src/re/include/"*.h "$HEADERS/"
cp "$WORK_DIR/src/baresip/include/baresip.h" "$HEADERS/"

rm -rf "$OUTPUT_DIR/CRMPhoneBaresip.xcframework"
xcodebuild -create-xcframework \
  -library "$WORK_DIR/libCRMPhoneBaresip-device.a" -headers "$HEADERS" \
  -library "$WORK_DIR/libCRMPhoneBaresip-simulator.a" -headers "$HEADERS" \
  -output "$OUTPUT_DIR/CRMPhoneBaresip.xcframework"

echo "Built $OUTPUT_DIR/CRMPhoneBaresip.xcframework"
