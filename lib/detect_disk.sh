#!/usr/bin/env bash
# =============================================================================
# lib/detect_disk.sh — Disk detection and role handling
# =============================================================================
# Manages primary OS disk detection and secondary disk handling based on
# INSTALL_ROLE ("standard" vs "storage-vps").
# =============================================================================

set -euo pipefail

detect_disk() {
    echo "==> Detecting primary OS disk..."

    INSTALL_ROLE="${INSTALL_ROLE:-standard}"
    if [[ "${INSTALL_ROLE}" != "standard" && "${INSTALL_ROLE}" != "storage-vps" ]]; then
        echo "ERROR: Invalid INSTALL_ROLE '${INSTALL_ROLE}'. Supported values: standard, storage-vps" >&2
        return 1
    fi

    # If DISK is manually specified in config.env, validate it
    if [[ -n "${DISK:-}" ]]; then
        if [[ -b "${DISK}" ]]; then
            echo "    Using manually configured disk: ${DISK}"
            export DISK
            VG_NAME="${HOSTNAME:-vps}-vol"
            export VG_NAME
            return 0
        else
            echo "ERROR: Configured DISK '${DISK}' does not exist or is not a block device." >&2
            return 1
        fi
    fi

    local detected_disk=""

    # Detect disk containing root filesystem ('/')
    local root_device
    root_device=$(findmnt -n -o SOURCE / 2>/dev/null | head -n1)
    if [[ -n "${root_device}" ]]; then
        # Strip subvolume specifier if present (e.g., /dev/mapper/root[/@])
        root_device="${root_device%%\[*}"
        # Resolve symlinks (e.g., /dev/mapper/... -> /dev/dm-0)
        root_device=$(readlink -f "${root_device}" 2>/dev/null || echo "${root_device}")

        # Trace device dependency tree upwards to find parent disk device
        local parent_disk_names
        parent_disk_names=$(lsblk -s -n -o NAME,TYPE "${root_device}" 2>/dev/null \
            | awk '$2 == "disk" {print $1}' \
            | tr -dc 'a-zA-Z0-9_\n-' \
            | sort -u)

        local disk_count
        disk_count=$(echo "${parent_disk_names}" | grep -c . || echo 0)

        if (( disk_count > 1 )); then
            echo "ERROR: The root filesystem spans multiple physical disks:" >&2
            echo "${parent_disk_names}" | sed 's/^/       /dev/' >&2
            echo "       Please set DISK=\"/dev/...\" in config.env to choose the target disk." >&2
            return 1
        fi

        local parent_disk_name
        parent_disk_name=$(echo "${parent_disk_names}" | head -n1)

        if [[ -n "${parent_disk_name}" ]]; then
            detected_disk="/dev/${parent_disk_name}"
        elif [[ "${root_device}" == /dev/nvme* ]]; then
            # NVMe: /dev/nvme0n1p1 -> /dev/nvme0n1
            # shellcheck disable=SC2001
            detected_disk=$(echo "${root_device}" | sed 's/p[0-9]*$//')
        else
            # Standard: /dev/sda1 -> /dev/sda, /dev/vda1 -> /dev/vda
            # shellcheck disable=SC2001
            detected_disk=$(echo "${root_device}" | sed 's/[0-9]*$//')
        fi
    fi

    if [[ -z "${detected_disk}" ]] || [[ ! -b "${detected_disk}" ]]; then
        echo "ERROR: Could not safely auto-detect primary OS disk from root mount (/)." >&2
        echo "       For safety, guessing by disk size is disabled." >&2
        echo "       Please set DISK=\"/dev/sda\" (or your specific disk) in config.env." >&2
        return 1
    fi

    DISK="${detected_disk}"
    export DISK

    VG_NAME="${HOSTNAME:-vps}-vol"
    export VG_NAME

    local disk_size disk_model
    disk_size=$(lsblk -dnbo SIZE "${DISK}" 2>/dev/null | head -n1)
    disk_model=$(lsblk -dno MODEL "${DISK}" 2>/dev/null | head -n1 | sed 's/^[[:space:]]*//')

    if [[ -n "${disk_size}" ]]; then
        disk_size=$(numfmt --to=iec-i --suffix=B "${disk_size}" 2>/dev/null || echo "${disk_size} bytes")
    fi

    echo "    Detected primary OS disk: ${DISK} (${disk_size:-unknown size}${disk_model:+, ${disk_model}})"
}

# Secondary disk handling based on INSTALL_ROLE
detect_secondary_disks() {
    EXTRA_DISKS=""
    MOUNT_EXTRA_DISKS=""

    if [[ "${INSTALL_ROLE}" == "standard" ]]; then
        echo "==> INSTALL_ROLE='standard': Secondary disks are completely ignored."
        export EXTRA_DISKS MOUNT_EXTRA_DISKS
        return 0
    fi

    echo "==> INSTALL_ROLE='storage-vps': Scanning for additional storage disks..."

    local found_disks=()
    while read -r name; do
        local dev="/dev/${name}"
        if [[ "${dev}" != "${DISK}" ]] && [[ -b "${dev}" ]]; then
            found_disks+=("${dev}")
        fi
    done < <(lsblk -dnbo NAME,TYPE,RM 2>/dev/null | awk '$2 == "disk" && $3 == "0" {print $1}')

    if (( ${#found_disks[@]} == 0 )); then
        echo "    No secondary storage disks found."
        export EXTRA_DISKS MOUNT_EXTRA_DISKS
        return 0
    fi

    local approved_disks=()

    echo ""
    echo "─────────────────────────────────────────────────────────────"
    echo "           Detected Additional Storage Disks                 "
    echo "─────────────────────────────────────────────────────────────"

    for dev in "${found_disks[@]}"; do
        local size model parts
        size=$(lsblk -dnbo SIZE "${dev}" 2>/dev/null | head -n1)
        [[ -n "${size}" ]] && size=$(numfmt --to=iec-i --suffix=B "${size}" 2>/dev/null || echo "${size}")
        model=$(lsblk -dno MODEL "${dev}" 2>/dev/null | head -n1 | sed 's/^[[:space:]]*//')
        parts=$(lsblk -n -o NAME,SIZE,FSTYPE,MOUNTPOINTS "${dev}" 2>/dev/null || echo "Unknown")

        echo ""
        echo "  Device: ${dev}"
        echo "  Size:   ${size:-unknown}"
        echo "  Model:  ${model:-Generic/Virtual}"
        echo "  Current Layout:"
        # shellcheck disable=SC2001
        echo "${parts}" | sed 's/^/    /'
        echo ""

        # If in dry-run or non-interactive mode, default to untouched unless user specified
        if [[ "${DRY_RUN:-false}" == true ]] || [[ ! -t 0 ]]; then
            echo "  [Non-interactive / Dry Run] Keeping ${dev} UNTOUCHED by default."
            continue
        fi

        echo "  Select action for ${dev}:"
        echo "    1) Leave untouched (DO NOT format or mount) [default]"
        echo "    2) Format (ext4) and mount under /mnt/${HOSTNAME:-vps}-vol"
        echo "    3) Manual configuration (skip auto-handling)"
        read -rp "  Choice [1-3]: " choice
        choice="${choice:-1}"

        case "${choice}" in
            2)
                read -rp "  Type the full device path '${dev}' to confirm formatting: " confirm_dev
                if [[ "${confirm_dev}" == "${dev}" ]]; then
                    echo "  ✓ Marked ${dev} for formatting and mounting."
                    approved_disks+=("${dev}")
                else
                    echo "  ✗ Confirmation did not match. Left ${dev} untouched."
                fi
                ;;
            3)
                echo "  ✓ Skipped ${dev} (manual configuration)."
                ;;
            *)
                echo "  ✓ Left ${dev} untouched."
                ;;
        esac
    done
    echo "─────────────────────────────────────────────────────────────"

    if (( ${#approved_disks[@]} > 0 )); then
        # shellcheck disable=SC2001
        MOUNT_EXTRA_DISKS=$(echo "${approved_disks[*]}" | sed 's/ *$//')
    fi

    export EXTRA_DISKS MOUNT_EXTRA_DISKS
}

detect_boot_mode() {
    if [[ -d /sys/firmware/efi ]]; then
        BOOT_MODE="uefi"
        echo "    Boot mode: UEFI"
    else
        BOOT_MODE="bios"
        echo "    Boot mode: BIOS/Legacy"
    fi
    export BOOT_MODE
}

print_disk_config() {
    local disk_size disk_model disk_tree
    disk_size=$(lsblk -dnbo SIZE "${DISK}" 2>/dev/null | head -n1)
    disk_model=$(lsblk -dno MODEL "${DISK}" 2>/dev/null | head -n1 | sed 's/^[[:space:]]*//')
    if [[ -n "${disk_size}" ]]; then
        disk_size=$(numfmt --to=iec-i --suffix=B "${disk_size}" 2>/dev/null || echo "${disk_size}")
    fi
    disk_tree=$(lsblk -n -o NAME,SIZE,FSTYPE,MOUNTPOINTS "${DISK}" 2>/dev/null || echo "Unknown")

    echo ""
    echo "┌─────────────────────────────────────────────────────┐"
    echo "│             Disk Configuration                      │"
    echo "├─────────────────────────────────────────────────────┤"
    printf "│  %-16s  %-32s │\n" "Install Role:" "${INSTALL_ROLE}"
    printf "│  %-16s  %-32s │\n" "Target OS Disk:" "${DISK}"
    printf "│  %-16s  %-32s │\n" "Disk Size:" "${disk_size:-unknown}"
    printf "│  %-16s  %-32s │\n" "Model:" "${disk_model:-Generic/Virtual}"
    printf "│  %-16s  %-32s │\n" "Volume Group:" "${VG_NAME:-${HOSTNAME}-vol}"
    if [[ "${INSTALL_ROLE}" == "standard" ]]; then
        printf "│  %-16s  %-32s │\n" "Secondary Disks:" "Ignored (standard mode)"
    else
        printf "│  %-16s  %-32s │\n" "Storage Disks:" "${MOUNT_EXTRA_DISKS:-None selected}"
    fi
    printf "│  %-16s  %-32s │\n" "Boot Mode:" "${BOOT_MODE:-unknown}"
    echo "├─────────────────────────────────────────────────────┤"
    echo "│ Current OS Disk Layout:                             │"
    # shellcheck disable=SC2001
    echo "${disk_tree}" | sed 's/^/│   /'
    echo "└─────────────────────────────────────────────────────┘"
    echo ""
}
