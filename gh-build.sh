#!/usr/bin/env bash

# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 Nitrux Latinoamericana S.C.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
export NVIDIA_BRANCH="${NVIDIA_BRANCH:-610}"
NVIDIA_VERSION_FULL="$(tr -d '[:space:]' < "$ROOT_DIR/NVIDIA_VERSION")"
export NVIDIA_VERSION_FULL
export NVIDIA_PACKAGE_VERSION="${NVIDIA_PACKAGE_VERSION:-${NVIDIA_VERSION_FULL}-101nitrux1}"
KERNEL_VERSION="${KERNEL_VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
export KERNEL_VERSION
KERNEL_MAKE_JOBS="${KERNEL_MAKE_JOBS:-$(nproc)}"
export KERNEL_MAKE_JOBS
export DEB_BUILD_MAINT_OPTIONS="${DEB_BUILD_MAINT_OPTIONS:-optimize=+lto}"
export SKIP_BUILD_DEPS="${SKIP_BUILD_DEPS:-0}"
export BUILD_SUPPORT_PACKAGES="${BUILD_SUPPORT_PACKAGES:-1}"
export BUILD_EGL_WAYLAND2="${BUILD_EGL_WAYLAND2:-0}"

cd "$ROOT_DIR"
TARGET_ARCH="${TARGET_ARCH:-$(dpkg --print-architecture)}"
export TARGET_ARCH

if [ "${CI:-}" != "true" ] && [ "${NVIDIA_BUILD_LOG_ACTIVE:-0}" != "1" ]; then
    LOG_FILE="$ROOT_DIR/gh-build-$(date +%Y%m%d-%H%M%S).log"
    export NVIDIA_BUILD_LOG_ACTIVE=1
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "Logging build output to $LOG_FILE"
fi

case "$TARGET_ARCH" in
    amd64)
        DEFAULT_NVIDIA_ARCH_FLAGS="-march=x86-64-v3"
        DEFAULT_DEB_ARCH_FLAGS="-march=x86-64-v3"
        NVIDIA_RUNFILE_ARCH="x86_64"
        ;;
    arm64)
        DEFAULT_NVIDIA_ARCH_FLAGS=""
        DEFAULT_DEB_ARCH_FLAGS=""
        NVIDIA_RUNFILE_ARCH="aarch64"
        ;;
    *)
        echo "Unsupported architecture: $TARGET_ARCH" >&2
        exit 1
        ;;
esac

export NVIDIA_ARCH_FLAGS="${NVIDIA_ARCH_FLAGS:-$DEFAULT_NVIDIA_ARCH_FLAGS}"
export DEB_CFLAGS_MAINT_APPEND="${DEB_CFLAGS_MAINT_APPEND:-$DEFAULT_DEB_ARCH_FLAGS -O3 -flto=auto}"
export DEB_CXXFLAGS_MAINT_APPEND="${DEB_CXXFLAGS_MAINT_APPEND:-$DEFAULT_DEB_ARCH_FLAGS -O3 -flto=auto}"
export DEB_LDFLAGS_MAINT_APPEND="${DEB_LDFLAGS_MAINT_APPEND:-$DEFAULT_DEB_ARCH_FLAGS -O3 -flto=auto}"

case "$KERNEL_VERSION" in
    "$NVIDIA_BRANCH".*)
        echo "KERNEL_VERSION appears to contain the NVIDIA driver version ($KERNEL_VERSION)." >&2
        echo "Put the kernel package version in VERSION and the NVIDIA driver version in NVIDIA_VERSION." >&2
        exit 1
        ;;
esac


if [ "$NVIDIA_BRANCH" != "610" ]; then
    echo "The imported NVIDIA user-space metadata currently targets branch 610." >&2
    echo "Use NVIDIA_BRANCH=610 or update packages/nvidia-graphics-drivers-610 first." >&2
    exit 1
fi


if [ ! -d "/lib/modules/$KERNEL_VERSION/build" ]; then
    echo "Missing kernel headers: linux-headers-$KERNEL_VERSION" >&2
    exit 1
fi

if [ "$SKIP_BUILD_DEPS" != "1" ] && command -v apt-get >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
        APT=(apt-get)
    elif command -v sudo >/dev/null 2>&1; then
        APT=(sudo apt-get)
    else
        echo "Install build dependencies manually or use SKIP_BUILD_DEPS=1." >&2
        exit 1
    fi
    "${APT[@]}" update -y
    "${APT[@]}" install -y build-essential debhelper-compat devscripts fakeroot git wget xz-utils libgstreamer-plugins-bad1.0-dev clang
fi

rm -rf "$ROOT_DIR/work" "$ROOT_DIR/output"
mkdir -p "$ROOT_DIR/work" "$ROOT_DIR/output"

build_driver_userspace() {
    local src="$ROOT_DIR/work/nvidia-graphics-drivers-$NVIDIA_BRANCH"
    cp -a "$ROOT_DIR/packages/nvidia-graphics-drivers-$NVIDIA_BRANCH" "$src"

    while IFS= read -r file; do
        sed -i \
            -e "s/610\.57\.04/$NVIDIA_VERSION_FULL/g" \
            -e "s/101nitrux1/${NVIDIA_PACKAGE_VERSION##*-}/g" \
            "$file"
    done < <(find "$src/debian" -type f -not -path '*/source/format' -print)

    cd "$src"
    wget -nv "https://us.download.nvidia.com/XFree86/Linux-$NVIDIA_RUNFILE_ARCH/$NVIDIA_VERSION_FULL/NVIDIA-Linux-$NVIDIA_RUNFILE_ARCH-$NVIDIA_VERSION_FULL.run" \
        -O nvidia-installer.run
    chmod +x nvidia-installer.run
    apt-get build-dep ./ -y
    dpkg-buildpackage --no-sign --build=binary
    find "$ROOT_DIR/work" -maxdepth 1 -type f -name '*.deb' -exec cp -f {} "$ROOT_DIR/output/" \;
}

build_upstream_deb() {
    local name="$1" url="$2" metadata="$3"
    local src="$ROOT_DIR/work/$name"
    git clone --depth 1 "$url" "$src"
    cp -a "$ROOT_DIR/packages/$metadata/debian" "$src/"
    if [ -d "$ROOT_DIR/packages/$metadata/patches" ]; then
        cp -a "$ROOT_DIR/packages/$metadata/patches" "$src/"
        while IFS= read -r patch_name; do
            [ -z "$patch_name" ] && continue
            patch -Np1 --batch --forward -i "$ROOT_DIR/packages/$metadata/patches/$patch_name"
        done < "$ROOT_DIR/packages/$metadata/patches/series"
    fi
    cd "$src"
    apt-get build-dep ./ -y
    dpkg-buildpackage --no-sign --build=binary
    find "$ROOT_DIR/work" -maxdepth 1 -type f -name '*.deb' -exec cp -f {} "$ROOT_DIR/output/" \;
}

build_support() {
    [ "$BUILD_SUPPORT_PACKAGES" = "1" ] || return 0
    build_upstream_deb egl-wayland https://github.com/NVIDIA/egl-wayland.git egl-wayland
    build_upstream_deb nvidia-egl-gbm https://github.com/NVIDIA/egl-gbm.git nvidia-egl-gbm
    build_upstream_deb nvidia-vaapi-driver https://github.com/elFarto/nvidia-vaapi-driver.git nvidia-vaapi-driver
    if [ "$BUILD_EGL_WAYLAND2" = "1" ]; then
        build_upstream_deb egl-wayland2 https://github.com/NVIDIA/egl-wayland2.git egl-wayland2
    fi
}

build_meta_package() {
    local src="$ROOT_DIR/work/nitrux-nvidia"
    cp -a "$ROOT_DIR/packages/nitrux-nvidia" "$src"
    sed -i \
        -e "s/580/610/g" \
        -e "s/595/610/g" \
        -e "s/^Architecture: amd64$/Architecture: $TARGET_ARCH/" \
        -e "s/nitrux-kernel-legacy/linux-image-$KERNEL_VERSION, linux-headers-$KERNEL_VERSION/g" \
        -e "s/libnvidia-egl-wayland2/libnvidia-egl-wayland1/g" \
        "$src/debian/control"
    sed -i "1s/.*/nitrux-nvidia ($NVIDIA_PACKAGE_VERSION) unstable; urgency=medium/" "$src/debian/changelog"
    cd "$src"
    dpkg-buildpackage --no-sign --build=binary
    find "$ROOT_DIR/work" -maxdepth 1 -type f -name '*.deb' -exec cp -f {} "$ROOT_DIR/output/" \;
}

echo "Building NVIDIA $NVIDIA_VERSION_FULL user-space packages"
build_driver_userspace
build_support

source_deb="$(find "$ROOT_DIR/output" -maxdepth 1 -type f -name "nvidia-open-kernel-source-${NVIDIA_BRANCH}_*.deb" -print -quit)"
[ -n "$source_deb" ] || { echo "The user-space build produced no open kernel source package." >&2; exit 1; }

echo "Building open kernel modules for $KERNEL_VERSION"
NVIDIA_SOURCE_DEB="$source_deb" \
    BUILD_ROOT="$ROOT_DIR/work/modules" OUTPUT_DIR="$ROOT_DIR/output" \
    KERNEL_VERSION="$KERNEL_VERSION" NVIDIA_BRANCH="$NVIDIA_BRANCH" \
    NVIDIA_PACKAGE_VERSION="$NVIDIA_PACKAGE_VERSION" KERNEL_MAKE_JOBS="$KERNEL_MAKE_JOBS" \
    NVIDIA_ARCH_FLAGS="$NVIDIA_ARCH_FLAGS" SKIP_BUILD_DEPS=1 \
    "$ROOT_DIR/build-modules.sh"

build_meta_package
echo "All NVIDIA packages are in: $ROOT_DIR/output"
