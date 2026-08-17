#!/usr/bin/env bash

# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 Nitrux Latinoamericana S.C.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/work/modules}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output}"
cd "$ROOT_DIR"

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
KERNEL_VERSION="${KERNEL_VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
export KERNEL_VERSION
export NVIDIA_BRANCH="${NVIDIA_BRANCH:-610}"
export NVIDIA_SOURCE_PACKAGE="${NVIDIA_SOURCE_PACKAGE:-nvidia-open-kernel-source-${NVIDIA_BRANCH}}"
export NVIDIA_SOURCE_VERSION="${NVIDIA_SOURCE_VERSION:-}"
export NVIDIA_PACKAGE_VERSION="${NVIDIA_PACKAGE_VERSION:-}"
KERNEL_MAKE_JOBS="${KERNEL_MAKE_JOBS:-$(nproc)}"
export KERNEL_MAKE_JOBS
TARGET_ARCH="${TARGET_ARCH:-$(dpkg --print-architecture)}"
export TARGET_ARCH

if [ "${CI:-}" != "true" ] && [ "${NVIDIA_BUILD_LOG_ACTIVE:-0}" != "1" ]; then
    LOG_FILE="$ROOT_DIR/build-modules-$(date +%Y%m%d-%H%M%S).log"
    export NVIDIA_BUILD_LOG_ACTIVE=1
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "Logging build output to $LOG_FILE"
fi

case "$TARGET_ARCH" in
    amd64)
        DEFAULT_NVIDIA_ARCH_FLAGS="-march=x86-64-v3"
        ;;
    arm64)
        DEFAULT_NVIDIA_ARCH_FLAGS=""
        ;;
    *)
        echo "Unsupported architecture: $TARGET_ARCH" >&2
        exit 1
        ;;
esac

export NVIDIA_ARCH_FLAGS="${NVIDIA_ARCH_FLAGS:-$DEFAULT_NVIDIA_ARCH_FLAGS}"
export NVIDIA_IGNORE_CC_MISMATCH="${NVIDIA_IGNORE_CC_MISMATCH:-0}"
export SKIP_BUILD_DEPS="${SKIP_BUILD_DEPS:-0}"


if [ "$SKIP_BUILD_DEPS" != "1" ] && command -v apt-get >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
        APT=(apt-get)
    elif command -v sudo >/dev/null 2>&1; then
        APT=(sudo apt-get)
    else
        echo "Install the build dependencies manually or use SKIP_BUILD_DEPS=1." >&2
        exit 1
    fi

    "${APT[@]}" update -y
    "${APT[@]}" install -y \
        build-essential \
        clang \
        debhelper-compat \
        dpkg-dev \
        fakeroot \
        kmod \
        lld \
        llvm \
        xz-utils
fi

if [ ! -d "/lib/modules/${KERNEL_VERSION}/build" ]; then
    echo "Missing kernel headers: linux-headers-${KERNEL_VERSION}" >&2
    exit 1
fi

if [ -n "${NVIDIA_SOURCE_DEB:-}" ]; then
    [ -f "$NVIDIA_SOURCE_DEB" ] || { echo "NVIDIA_SOURCE_DEB does not exist: $NVIDIA_SOURCE_DEB" >&2; exit 1; }
    NVIDIA_SOURCE_VERSION="$(dpkg-deb -f "$NVIDIA_SOURCE_DEB" Version)"
elif [ -z "$NVIDIA_SOURCE_VERSION" ]; then
    NVIDIA_SOURCE_VERSION="$(apt-cache policy "$NVIDIA_SOURCE_PACKAGE" | awk '/Candidate:/{print $2; exit}')"
fi
if [ -z "$NVIDIA_SOURCE_VERSION" ] || [ "$NVIDIA_SOURCE_VERSION" = "(none)" ]; then
    echo "No source version found for ${NVIDIA_SOURCE_PACKAGE}." >&2
    exit 1
fi

if [ -z "$NVIDIA_PACKAGE_VERSION" ]; then
    NVIDIA_PACKAGE_VERSION="$NVIDIA_SOURCE_VERSION"
fi

CLANG_MAJOR="${CLANG_MAJOR:-$(clang -dumpversion | cut -d. -f1)}"
CLANG_BIN="${CLANG_BIN:-clang-${CLANG_MAJOR}}"
LD_BIN="${LD_BIN:-ld.lld-${CLANG_MAJOR}}"
LLVM_PREFIX="${LLVM_PREFIX:--${CLANG_MAJOR}}"
command -v "$CLANG_BIN" >/dev/null 2>&1 || CLANG_BIN=clang
command -v "$LD_BIN" >/dev/null 2>&1 || LD_BIN=ld.lld

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT/source" "$BUILD_ROOT/package" "$OUTPUT_DIR"

echo "Kernel: ${KERNEL_VERSION}"
echo "NVIDIA source: ${NVIDIA_SOURCE_PACKAGE}=${NVIDIA_SOURCE_VERSION}"
echo "Compiler: ${CLANG_BIN} / ${LD_BIN}"
echo "Architecture flags: ${NVIDIA_ARCH_FLAGS}"

cd "$BUILD_ROOT/source"
if [ -n "${NVIDIA_SOURCE_DEB:-}" ]; then
    cp "$NVIDIA_SOURCE_DEB" .
else
    apt download "${NVIDIA_SOURCE_PACKAGE}=${NVIDIA_SOURCE_VERSION}"
fi
SOURCE_DEB="$(find . -maxdepth 1 -type f -name "${NVIDIA_SOURCE_PACKAGE}_*.deb" -print -quit)"
[ -n "$SOURCE_DEB" ] || { echo "The NVIDIA source package was not downloaded." >&2; exit 1; }

mkdir extracted
dpkg-deb -x "$SOURCE_DEB" extracted
SOURCE_DIR="$(find "$BUILD_ROOT/source/extracted/usr/src" -type f -name Kbuild -printf '%h\n' -quit 2>/dev/null)"
[ -n "$SOURCE_DIR" ] || { echo "The NVIDIA package contains no Kbuild source tree." >&2; exit 1; }
UVM_DEVMEM="$SOURCE_DIR/nvidia-uvm/uvm_devmem.h"
if [ -f "$UVM_DEVMEM" ] && grep -q "WARN_ON(!coherent_devmem_page)" "$UVM_DEVMEM"; then
    perl -0pi -e "s/^[[:space:]]*WARN_ON\(!coherent_devmem_page\);$/            if (WARN_ON(!coherent_devmem_page))\n                return;/mg" "$UVM_DEVMEM"
fi

DRIVER_VERSION="$(awk -F '"' '/NV_VERSION_STRING=/{print $2; exit}' \
    "$SOURCE_DIR/Kbuild" | tr -d '\\')"
DRIVER_VERSION="${DRIVER_VERSION:-${NVIDIA_BRANCH}}"

PKG_DIR="$BUILD_ROOT/package"
cp "$ROOT_DIR/blacklist-nouveau.conf" "$PKG_DIR/"
cp "$ROOT_DIR/nitrux-nvidia.conf" "$PKG_DIR/"
mkdir -p "$PKG_DIR/debian"

MODULE_PACKAGE="linux-modules-nvidia-open-${NVIDIA_BRANCH}-${KERNEL_VERSION}"
PROVIDER_PACKAGE="nvidia-open-kernel-module-${NVIDIA_BRANCH}"

cat > "$PKG_DIR/debian/control" <<EOF
Source: linux-nvidia-open-modules
Section: non-free/kernel
Priority: optional
Maintainer: Nitrux Latinoamericana S.C. <hello@nxos.org>
Build-Depends: debhelper-compat (= 13), linux-image-${KERNEL_VERSION}, linux-headers-${KERNEL_VERSION}, clang, lld, fakeroot
Standards-Version: 4.6.2
Rules-Requires-Root: no

Package: ${MODULE_PACKAGE}
Architecture: ${TARGET_ARCH}
Depends: linux-image-${KERNEL_VERSION}, linux-headers-${KERNEL_VERSION}, \${misc:Depends}
Provides: linux-modules-nvidia-${KERNEL_VERSION}, nvidia-open-kernel-module-${NVIDIA_BRANCH}
Description: NVIDIA ${DRIVER_VERSION} open kernel modules for ${KERNEL_VERSION}
 Prebuilt NVIDIA open kernel modules compiled with the matching kernel headers.

Package: ${PROVIDER_PACKAGE}
Architecture: ${TARGET_ARCH}
Depends: ${MODULE_PACKAGE} (= \${binary:Version})
Description: NVIDIA ${NVIDIA_BRANCH} open kernel module provider
 Dependency provider for the prebuilt NVIDIA open kernel modules.
EOF

printf 'usr\n' > "$PKG_DIR/debian/${MODULE_PACKAGE}.install"

cat > "$PKG_DIR/debian/rules" <<EOF
#!/usr/bin/make -f

SOURCE_DIR := ${SOURCE_DIR}
KERNEL_VERSION := ${KERNEL_VERSION}
MAKE_JOBS := ${KERNEL_MAKE_JOBS}
CLANG_BIN := ${CLANG_BIN}
LD_BIN := ${LD_BIN}
LLVM_PREFIX := ${LLVM_PREFIX}
ARCH_FLAGS := ${NVIDIA_ARCH_FLAGS}
DRIVER_VERSION := ${DRIVER_VERSION}
IGNORE_CC_MISMATCH := ${NVIDIA_IGNORE_CC_MISMATCH}
CLANG_INCLUDE := \$(shell \$(CLANG_BIN) -print-resource-dir)/include
KCFLAGS := -isystem \$(CLANG_INCLUDE) -I\$(SOURCE_DIR)/common/inc -I\$(SOURCE_DIR) \$(ARCH_FLAGS)

%:
	dh \$@

override_dh_auto_build:
	make -C \$(SOURCE_DIR) KERNEL_UNAME=\$(KERNEL_VERSION) \\
		CC=\$(CLANG_BIN) LD=\$(LD_BIN) LLVM=\$(LLVM_PREFIX) LLVM_IAS=1 \\
		IGNORE_CC_MISMATCH=\$(IGNORE_CC_MISMATCH) \\
		KCFLAGS="\$(KCFLAGS)" -j\$(MAKE_JOBS) modules

override_dh_auto_install:
	install -d \$(CURDIR)/debian/${MODULE_PACKAGE}/usr/lib/modules/\$(KERNEL_VERSION)/updates/dkms
	find \$(SOURCE_DIR) -maxdepth 1 -type f -name '*.ko' -exec install -m644 {} \$(CURDIR)/debian/${MODULE_PACKAGE}/usr/lib/modules/\$(KERNEL_VERSION)/updates/dkms/ \;
	install -D -m644 blacklist-nouveau.conf \$(CURDIR)/debian/${MODULE_PACKAGE}/usr/lib/modprobe.d/blacklist-nouveau.conf
	install -D -m644 nitrux-nvidia.conf \$(CURDIR)/debian/${MODULE_PACKAGE}/usr/lib/modules-load.d/nitrux-nvidia.conf

override_dh_install:
	dh_missing --fail-missing

override_dh_auto_clean:
	true
EOF
chmod +x "$PKG_DIR/debian/rules"

cat > "$PKG_DIR/debian/changelog" <<EOF
linux-nvidia-open-modules (${NVIDIA_PACKAGE_VERSION}) unstable; urgency=medium

  * Build NVIDIA ${DRIVER_VERSION} open modules for ${KERNEL_VERSION} with ${CLANG_BIN}.

 -- Nitrux Latinoamericana S.C. <hello@nxos.org>  $(LC_ALL=C date -R)
EOF

cat > "$PKG_DIR/debian/postinst" <<EOF
#!/bin/sh
set -e
depmod -a '${KERNEL_VERSION}' || true
if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u -k '${KERNEL_VERSION}' || true
fi
EOF
cp "$PKG_DIR/debian/postinst" "$PKG_DIR/debian/postrm"
chmod +x "$PKG_DIR/debian/postinst" "$PKG_DIR/debian/postrm"

cd "$PKG_DIR"
dpkg-buildpackage --no-sign --build=binary
find "$BUILD_ROOT" -maxdepth 1 -type f -name '*.deb' -exec cp -f {} "$OUTPUT_DIR/" \;

echo "Build completed. Artifacts are in: $OUTPUT_DIR"
