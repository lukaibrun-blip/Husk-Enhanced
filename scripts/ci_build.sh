#!/bin/bash
# Husk: build everything from a clean checkout to the IPA, in order.
#
# Runs on macOS with Xcode. Usage: ./scripts/ci_build.sh [output.ipa]
set -euo pipefail

HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HUSK_ROOT/build/Husk.ipa}"
cd "$HUSK_ROOT"

step() { printf '\n\033[1;34m##### %s\033[0m\n' "$*"; }

step "fetch sources"
./scripts/fetch_sources.sh

step "dependencies: libffi glib pixman libucontext libslirp"
./scripts/build_ios.sh libffi glib pixman libucontext libslirp

# build_gpu_ios.sh asks for cross-ios-darwin.meson, which no script generates.
# build_ios.sh writes cross-darwin.meson, the file it describes (host system
# darwin, subsystem ios), under a different name.
cp build/ios-arm64/cross-darwin.meson build/ios-arm64/cross-ios-darwin.meson

if [ ! -f build/ios-arm64/sysroot/lib/libANGLE-shared.dylib ]; then
    step "ANGLE (EGL/GLES over Metal)"
    ./scripts/build_angle_ios.sh
fi

if [ ! -f build/ios-arm64/sysroot/lib/libvirglrenderer.a ]; then
    step "libepoxy + virglrenderer"
    # build_ios.sh's cross environment, which the GPU script assumes is set.
    PKG_CONFIG_LIBDIR="$HUSK_ROOT/build/ios-arm64/sysroot/lib/pkgconfig:$HUSK_ROOT/build/ios-arm64/sysroot/share/pkgconfig" \
        ./scripts/build_gpu_ios.sh
fi

step "QEMU"
./scripts/build_ios.sh qemu

step "integrate Husk sources into QEMU, then rebuild it"
./scripts/integrate_husk.sh
./scripts/build_ios.sh qemurebuild

step "guest kernel + firmware"
./scripts/fetch_phase0_guest.sh

if [ ! -d build/ios-arm64/lib/MoltenVK.xcframework ]; then
    step "MoltenVK (Vulkan over Metal, for Unreal Engine games)"
    ./scripts/build_moltenvk_ios.sh
fi

step "on-device pairing (Rust)"
./scripts/build_rppairing_ios.sh

PS4_CORE="${BACHATA_DIR:-$HOME/Documents/Coding/AetherCore4/Bachata-S4}"
PS4_FEX="${HUSK_FEX_DIR:-$HOME/Documents/Coding/husk-fex}"
if [ -d "$PS4_CORE/.git" ] && [ -d "$PS4_FEX/.git" ]; then
    step "optional PS4 layer"
    BACHATA_DIR="$PS4_CORE" HUSK_FEX_DIR="$PS4_FEX" ./scripts/build_ps4_ios.sh
else
    step "optional PS4 layer omitted (separate Bachata-S4 and FEXCore checkouts not present)"
fi

step "app + IPA"
mkdir -p "$(dirname "$OUT")"
./scripts/package_ipa.sh "$OUT"
./scripts/package_ipa.sh --trollstore "${OUT%.ipa}.tipa"
