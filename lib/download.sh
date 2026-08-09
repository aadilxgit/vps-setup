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
    local clean_mirror="${DEBIAN_MIRROR%/}"
    if [[ "${clean_mirror}" == "http://deb.debian.org/debian" ]]; then
        clean_mirror="https://deb.debian.org/debian"
    elif [[ "${clean_mirror}" == "http://ftp.debian.org/debian" ]]; then
        clean_mirror="https://ftp.debian.org/debian"
    fi

    if [[ -n "${clean_mirror}" && "${clean_mirror}" != https://* ]]; then
        echo "ERROR: DEBIAN_MIRROR must use HTTPS." >&2
        return 1
    fi
    local release="${DEBIAN_RELEASE:-trixie}"

    echo "==> Downloading Debian ${release} netboot files..."
    mkdir -p "${work_dir}"
    # Install wget if not available
    if ! command -v wget &>/dev/null; then
        echo "    Installing wget..."
        apt-get update -qq && apt-get install -y -qq wget
    fi

    # Define candidate mirrors — HTTPS only to prevent on-path kernel/initrd tampering
    # An attacker substituting artifacts over HTTP would gain code execution via kexec
    local mirrors=(
        "${clean_mirror}"
        "https://deb.debian.org/debian"
        "https://cdn-fastly.deb.debian.org/debian"
        "https://ftp.debian.org/debian"
    )

    local relative_paths=(
        "dists/${release}/main/installer-amd64/current/images/netboot/debian-installer/amd64"
        "dists/${release}/main/installer-amd64/current/legacy-images/netboot/debian-installer/amd64"
    )

    local kernel_success=false
    local initrd_success=false
    local working_base_url=""

    for m in "${mirrors[@]}"; do
        m="${m%/}"
        for p in "${relative_paths[@]}"; do
            local base_url="${m}/${p}"
            local kernel_url="${base_url}/linux"
            local initrd_url="${base_url}/initrd.gz"

            echo "    Attempting source: ${base_url}..."

            if wget --https-only -q --show-progress -O "${work_dir}/linux" "${kernel_url}"; then
                local k_size
                k_size=$(stat -c%s "${work_dir}/linux" 2>/dev/null || echo 0)
                if (( k_size >= 1000000 )); then
                    echo "    ✓ Downloaded kernel ($(numfmt --to=iec-i --suffix=B "${k_size}" 2>/dev/null || echo "${k_size} bytes"))"
                    kernel_success=true
                fi
            fi

            if [[ "${kernel_success}" == true ]]; then
                if wget --https-only -q --show-progress -O "${work_dir}/initrd.gz" "${initrd_url}"; then
                    local i_size
                    i_size=$(stat -c%s "${work_dir}/initrd.gz" 2>/dev/null || echo 0)
                    if (( i_size >= 1000000 )); then
                        echo "    ✓ Downloaded initrd.gz ($(numfmt --to=iec-i --suffix=B "${i_size}" 2>/dev/null || echo "${i_size} bytes"))"
                        initrd_success=true
                        working_base_url="${base_url}"
                        break 2
                    fi
                fi
            fi

            # Cleanup partial downloads before retrying
            rm -f "${work_dir}/linux" "${work_dir}/initrd.gz" 2>/dev/null || true
            kernel_success=false
        done
    done

    if [[ "${kernel_success}" != true || "${initrd_success}" != true ]]; then
        echo "ERROR: Could not download valid Debian netboot files from any mirror." >&2
        echo "       Please check your network connection or DEBIAN_MIRROR setting." >&2
        return 1
    fi

    # Download and verify SHA256SUMS from mirror metadata
    # SECURITY: fail closed — both linux AND initrd.gz must verify or we abort.
    # The next step executes this kernel via kexec; unverified artifacts = code execution.
    local sums_found=false
    local candidate_sums=(
        "${working_base_url}/SHA256SUMS"
        "${working_base_url%/netboot/debian-installer/amd64}/SHA256SUMS"
        "${working_base_url%/debian-installer/amd64}/SHA256SUMS"
    )

    for s_url in "${candidate_sums[@]}"; do
        if wget --https-only -q -O "${work_dir}/SHA256SUMS.raw" "${s_url}" 2>/dev/null; then
            echo "    Verifying SHA256 checksums (from ${s_url})..."
            # Extract ONLY the two entries we need — linux and initrd.gz
            # The raw file contains hundreds of PXE/GRUB entries under the same path;
            # keeping them causes sha256sum -c to fail on files we didn't download.
            grep -E 'netboot/debian-installer/amd64/(linux|initrd\.gz)$' "${work_dir}/SHA256SUMS.raw" 2>/dev/null \
                | sed 's|  .*/|  |g' > "${work_dir}/SHA256SUMS" 2>/dev/null || true

            # Verify BOTH files have matching entries (not just one via --ignore-missing)
            local have_linux=false have_initrd=false
            if [[ -s "${work_dir}/SHA256SUMS" ]]; then
                grep -q ' linux$' "${work_dir}/SHA256SUMS" 2>/dev/null && have_linux=true
                grep -q ' initrd\.gz$' "${work_dir}/SHA256SUMS" 2>/dev/null && have_initrd=true
            fi

            if [[ "${have_linux}" == true && "${have_initrd}" == true ]]; then
                if (cd "${work_dir}" && sha256sum -c SHA256SUMS &>/dev/null); then
                    echo "    ✓ SHA256 checksums verified for both linux and initrd.gz."
                    sums_found=true
                    break
                else
                    echo "    ✗ SHA256 checksum MISMATCH — artifacts may be corrupted or tampered." >&2
                fi
            fi
        fi
    done

    rm -f "${work_dir}/SHA256SUMS" "${work_dir}/SHA256SUMS.raw" 2>/dev/null || true

    if [[ "${sums_found}" != true ]]; then
        echo "ERROR: SHA256 checksum verification failed. Refusing to proceed with unverified artifacts." >&2
        echo "       This protects against on-path kernel/initrd substitution attacks." >&2
        rm -f "${work_dir}/linux" "${work_dir}/initrd.gz" 2>/dev/null || true
        return 1
    fi

    echo "    ✓ Netboot files ready in ${work_dir}/"
    echo ""
}
