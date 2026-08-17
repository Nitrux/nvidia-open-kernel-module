#! /bin/bash

# Check system for NVIDIA card and set vaapi env vars

if lspci -nnk 2>/dev/null | grep -A3 '\[03' | grep -q 'Kernel modules:.*nvidia'; then
    # Check if the default GPU is Intel/AMD/Radeon (using switcherooctl)
    if switcherooctl list 2>/dev/null | grep -A1 'Default' | grep -Eiq 'intel|amd|radeon|advanced'; then
        export MOZ_DISABLE_RDD_SANDBOX=1
        export NVD_BACKEND=direct
        [ -n "$XDG_SESSION_TYPE" ] && export EGL_PLATFORM="$XDG_SESSION_TYPE"
    else
        export LIBVA_DRIVER_NAME=nvidia
        export MOZ_DISABLE_RDD_SANDBOX=1
        export NVD_BACKEND=direct
        [ -n "$XDG_SESSION_TYPE" ] && export EGL_PLATFORM="$XDG_SESSION_TYPE"
    fi
fi