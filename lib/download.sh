#!/usr/bin/env bash
# =============================================================================
# lib/download.sh — Download Debian netboot files
# =============================================================================
# Downloads the Debian installer kernel (linux) and initrd (initrd.gz) from
# the official Debian mirrors for netboot installation.
# =============================================================================

set -euo pipefail

download_netboot_files() {
    local work_dir="${1:-.}"
    local base_url="${DEBIAN_MIRROR}/dists/${DEBIAN_RELEASE}/main/installer-amd64/current/images/netboot/debian-installer/amd64"
    local kernel_url="${base_url}/linux"
    local initrd_url="${base_url}/initrd.gz"

    echo "==> Downloading Debian ${DEBIAN_RELEASE} netboot files..."
    echo "    Source: ${base_url}"
    echo ""

    # Install wget if not available
    if ! command -v wget &>/dev/null; then
        echo "    Installing wget..."
        apt-get update -qq && apt-get install -y -qq wget
    fi

    # Download kernel
    if [[ -f "${work_dir}/linux" ]]; then
        echo "    Kernel already exists, re-downloading..."
    fi
    echo "    Downloading kernel..."
    wget -q --show-progress -O "${work_dir}/linux" "${kernel_url}" || {
        echo "ERROR: Failed to download kernel from ${kernel_url}" >&2
        echo "       Check your internet connection and DEBIAN_MIRROR setting." >&2
        return 1
    }

    # Download initrd
    if [[ -f "${work_dir}/initrd.gz" ]]; then
        echo "    initrd.gz already exists, re-downloading..."
    fi
    echo "    Downloading initrd.gz..."
    wget -q --show-progress -O "${work_dir}/initrd.gz" "${initrd_url}" || {
        echo "ERROR: Failed to download initrd.gz from ${initrd_url}" >&2
        return 1
    }

    # Verify files exist and have reasonable size
    local kernel_size initrd_size
    kernel_size=$(stat -c%s "${work_dir}/linux" 2>/dev/null || echo 0)
    initrd_size=$(stat -c%s "${work_dir}/initrd.gz" 2>/dev/null || echo 0)

    if (( kernel_size < 1000000 )); then
        echo "ERROR: Kernel file seems too small (${kernel_size} bytes). Download may have failed." >&2
        return 1
    fi
    if (( initrd_size < 1000000 )); then
        echo "ERROR: initrd.gz file seems too small (${initrd_size} bytes). Download may have failed." >&2
        return 1
    fi

    # Download and verify SHA256SUMS from mirror metadata
    local sums_url="${base_url}/SHA256SUMS"
    if wget -q -O "${work_dir}/SHA256SUMS" "${sums_url}" 2>/dev/null; then
        echo "    Verifying SHA256 checksums..."
        if (cd "${work_dir}" && sha256sum -c --ignore-missing SHA256SUMS &>/dev/null); then
            echo "    ✓ SHA256 checksums verified successfully."
        else
            echo "WARNING: SHA256 checksum verification failed for netboot files." >&2
        fi
        rm -f "${work_dir}/SHA256SUMS"
    fi

    echo "    ✓ Kernel:    $(numfmt --to=iec-i --suffix=B "${kernel_size}" 2>/dev/null || echo "${kernel_size} bytes")"
    echo "    ✓ initrd.gz: $(numfmt --to=iec-i --suffix=B "${initrd_size}" 2>/dev/null || echo "${initrd_size} bytes")"
    echo ""
}
