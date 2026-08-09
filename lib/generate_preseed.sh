#!/usr/bin/env bash
# =============================================================================
# lib/generate_preseed.sh — Generate preseed.cfg from template
# =============================================================================
# Replaces placeholders in templates/preseed.cfg.tmpl with actual values
# from config.env and auto-detected network/disk settings.
# =============================================================================

set -euo pipefail

sed_escape() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

generate_preseed() {
    local template_file="${SCRIPT_DIR}/templates/preseed.cfg.tmpl"
    local output_file="${WORK_DIR}/preseed.cfg"

    echo "==> Generating preseed.cfg..."

    if [[ ! -f "${template_file}" ]]; then
        echo "ERROR: Preseed template not found: ${template_file}" >&2
        return 1
    fi

    # Create output file with restricted permissions (600) before writing secrets
    install -m 600 /dev/null "${output_file}"

    # Generate random single-installation token if not already generated
    INSTALL_TOKEN="${INSTALL_TOKEN:-$(openssl rand -hex 16)}"
    export INSTALL_TOKEN

    # Generate temporary random LUKS key for automated installation
    TEMP_LUKS_KEY="${TEMP_LUKS_KEY:-$(openssl rand -hex 32)}"
    export TEMP_LUKS_KEY
    # Parse Debian mirror protocol, host and directory from DEBIAN_MIRROR URL
    local mirror_proto="http"
    if [[ "${DEBIAN_MIRROR}" == https://* ]]; then
        mirror_proto="https"
    fi
    local mirror_clean="${DEBIAN_MIRROR#*://}"
    local mirror_host="${mirror_clean%%/*}"
    local mirror_dir=""
    if [[ "${mirror_clean}" == *"/"* ]]; then
        mirror_dir="/${mirror_clean#*/}"
    else
        mirror_dir="/debian"
    fi

    # Determine first DNS server for preseed (netcfg only takes one)
    local primary_dns
    primary_dns=$(echo "${DNS_SERVERS}" | awk '{print $1}')

    # Domain must have a value or installer may prompt; default to "local"
    local domain_preseed="${DOMAIN:-local}"

    # Determine disk name without /dev/ prefix for preseed disk selection
    local disk_short="${DISK#/dev/}"
    local vg_name="${VG_NAME:-${HOSTNAME}-vol}"

    # Build boot-mode dependent partman expert recipe
    # Per Debian docs: recipe is a single-line string, each partition block ends with "."
    # CRITICAL: partman-auto-crypto scans for a partition with method{ crypto }
    # to know where to create the LUKS dm-crypt device. Without it, encrypted LVM
    # cannot be created. The crypto partition holds the LVM PV inside LUKS.
    # Layout: EFI/BIOS-boot → /boot → crypto(LUKS) → LVM(swap + root)
    local partman_recipe=""
    if [[ "${BOOT_MODE:-uefi}" == "uefi" ]]; then
        partman_recipe="boot-crypto :: 538 538 1075 free \$primary{ } \$iflabel{ gpt } \$reusemethod{ } method{ efi } format{ } . 512 512 512 ext4 \$primary{ } \$defaultignore{ } method{ format } format{ } use_filesystem{ } filesystem{ ext4 } mountpoint{ /boot } . 2048 10000 -1 ext4 \$defaultignore{ } method{ crypto } format{ } . 1024 1024 1024 linux-swap \$defaultignore{ } \$lvmok{ } lv_name{ swap } in_vg{ ${vg_name} } method{ swap } format{ } . 4096 10000 -1 ext4 \$defaultignore{ } \$lvmok{ } lv_name{ root } in_vg{ ${vg_name} } method{ format } format{ } use_filesystem{ } filesystem{ ext4 } mountpoint{ / } ."
    else
        partman_recipe="boot-crypto :: 1 1 1 free \$gptonly{ } \$primary{ } method{ biosgrub } . 512 512 512 ext4 \$primary{ } \$defaultignore{ } method{ format } format{ } use_filesystem{ } filesystem{ ext4 } mountpoint{ /boot } . 2048 10000 -1 ext4 \$defaultignore{ } method{ crypto } format{ } . 1024 1024 1024 linux-swap \$defaultignore{ } \$lvmok{ } lv_name{ swap } in_vg{ ${vg_name} } method{ swap } format{ } . 4096 10000 -1 ext4 \$defaultignore{ } \$lvmok{ } lv_name{ root } in_vg{ ${vg_name} } method{ format } format{ } use_filesystem{ } filesystem{ ext4 } mountpoint{ / } ."
    fi

    # Determine disk wipe mode (fast=false, secure=true)
    local erase_disks="false"
    if [[ "${WIPE_MODE:-fast}" == "secure" ]]; then
        erase_disks="true"
    fi

    # Perform template substitution with sed_escape helper
    sed \
        -e "s|__ERASE_DISKS__|${erase_disks}|g" \
        -e "s|__LOCALE__|$(sed_escape "${LOCALE}")|g" \
        -e "s|__KEYMAP__|$(sed_escape "${KEYMAP}")|g" \
        -e "s|__HOSTNAME__|$(sed_escape "${HOSTNAME}")|g" \
        -e "s|__DOMAIN__|$(sed_escape "${DOMAIN}")|g" \
        -e "s|__DOMAIN_PRESEED__|$(sed_escape "${domain_preseed}")|g" \
        -e "s|__TIMEZONE__|$(sed_escape "${TIMEZONE}")|g" \
        -e "s|__USERNAME__|$(sed_escape "${USERNAME}")|g" \
        -e "s|__TEMP_LUKS_KEY__|$(sed_escape "${TEMP_LUKS_KEY}")|g" \
        -e "s|__DISK__|$(sed_escape "${DISK}")|g" \
        -e "s|__DISK_SHORT__|$(sed_escape "${disk_short}")|g" \
        -e "s|__INTERFACE__|$(sed_escape "${INTERFACE}")|g" \
        -e "s|__IPV4_ADDRESS__|$(sed_escape "${IPV4_ADDRESS}")|g" \
        -e "s|__IPV4_NETMASK__|$(sed_escape "${IPV4_NETMASK}")|g" \
        -e "s|__IPV4_CIDR__|$(sed_escape "${IPV4_CIDR}")|g" \
        -e "s|__IPV4_GATEWAY__|$(sed_escape "${IPV4_GATEWAY}")|g" \
        -e "s|__PRIMARY_DNS__|$(sed_escape "${primary_dns}")|g" \
        -e "s|__DNS_SERVERS__|$(sed_escape "${DNS_SERVERS}")|g" \
        -e "s|__DEBIAN_MIRROR_PROTO__|$(sed_escape "${mirror_proto}")|g" \
        -e "s|__DEBIAN_MIRROR_HOST__|$(sed_escape "${mirror_host}")|g" \
        -e "s|__DEBIAN_MIRROR_DIR__|$(sed_escape "${mirror_dir}")|g" \
        -e "s|__DEBIAN_RELEASE__|$(sed_escape "${DEBIAN_RELEASE}")|g" \
        -e "s|__SSH_PORT__|$(sed_escape "${SSH_PORT}")|g" \
        -e "s|__EXTRA_PACKAGES__|$(sed_escape "${EXTRA_PACKAGES}")|g" \
        -e "s|__SSH_PUBKEY__|$(sed_escape "${SSH_PUBKEY}")|g" \
        -e "s|__VG_NAME__|$(sed_escape "${vg_name}")|g" \
        -e "s|__INSTALL_TOKEN__|$(sed_escape "${INSTALL_TOKEN}")|g" \
        -e "s|__PARTMAN_RECIPE__|$(sed_escape "${partman_recipe}")|g" \
        "${template_file}" > "${output_file}"

    echo "    ✓ Generated: ${output_file}"
    echo "    Disk: ${DISK}, User: ${USERNAME}, SSH Port: ${SSH_PORT}"
    echo ""
}
