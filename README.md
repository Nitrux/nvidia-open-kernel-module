# NVIDIA Packages for Nitrux

[![Generic badge](https://img.shields.io/badge/Arch-x64-yellowgreen.svg)](https://shields.io/)

<p align="center">
  <img width="128" height="128" src="https://raw.githubusercontent.com/Nitrux/luv-icon-theme/master/Luv/apps/64/nvidia-settings.svg">
</p>

# Introduction

This repository builds the Nitrux NVIDIA package set: NVIDIA user-space libraries and tools, EGL/GBM/VA-API support packages, Clang-built open kernel modules, and the Nitrux NVIDIA metapackage.

# Building

The driver version is read from `NVIDIA_VERSION`, and the target Nitrux kernel package version is read from `VERSION`.

Install the matching Nitrux kernel and headers, then run:

```sh
./gh-build.sh
```

To build another driver or kernel version, edit the version files before running the builder:

```sh
printf '610.58.02\n' > NVIDIA_VERSION
printf '7.1.9-nitrux\n' > VERSION
./gh-build.sh
```

The source package must be available from the configured APT repositories, and `linux-image-${KERNEL_VERSION}` plus `linux-headers-${KERNEL_VERSION}` must be installed locally.

When run locally, the builder saves a timestamped `gh-build-*.log` beside the script. GitHub Actions does not create this extra file because Actions already captures the complete log.

The builder supports native `amd64` and `arm64` builds.

# Licensing

This repository contains files under multiple licenses.

- Repository build and packaging automation is licensed under **BSD-3-Clause** (see `LICENSE`).
- Debian package metadata keeps its respective upstream licensing.
- NVIDIA source, installer, and package content retain their applicable upstream licensing.

# Issues

If you find problems with the contents of this repository, please create an issue and use the **🐞 Bug report** template.

## Submitting a bug report

Before submitting a bug, you should look at the [existing bug reports](https://github.com/Nitrux/nvidia-open-kernel-module/issues) to verify that no one has reported the bug already.

©2026 Nitrux Latinoamericana S.C.
