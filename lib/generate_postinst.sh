#!/usr/bin/env bash
# =============================================================================
# lib/generate_postinst.sh — Generate post-install script from template
# =============================================================================
# Replaces placeholders in templates/postinst.sh.tmpl with actual values.
# The post-install script runs inside the newly installed system via
# preseed late_command.
# =============================================================================

set -euo pipefail

sed_escape() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

generate_postinst() {
    local template_file="${SCRIPT_DIR}/templates/postinst.sh.tmpl"
    local output_file="${WORK_DIR}/postinst.sh"

    echo "==> Generating post-install script..."

    if [[ ! -f "${template_file}" ]]; then
        echo "ERROR: Post-install template not found: ${template_file}" >&2
        return 1
    fi

    # Create output file with restricted permissions (700) before writing secrets
    install -m 700 /dev/null "${output_file}"

    # Build initramfs IP string
    # Format: IP=<client-ip>:<server-ip>:<gateway>:<netmask>:<hostname>:<device>:<autoconf>
    # Leaving device empty allows klibc-ipconfig to auto-bind to the active interface
    local initramfs_ip="${IPV4_ADDRESS}::${IPV4_GATEWAY}:${IPV4_NETMASK}:${HOSTNAME}::none"

    # Generate random single-installation token for secret file endpoint
    INSTALL_TOKEN="${INSTALL_TOKEN:-$(openssl rand -hex 16)}"
    export INSTALL_TOKEN

    local token_dir="${WORK_DIR}/${INSTALL_TOKEN}"
    mkdir -p "${token_dir}"
    chmod 700 "${token_dir}"

    # Write encrypted LUKS secret payload to restricted file (${INSTALL_TOKEN}/.secret_keys.enc)
    # Payload is AES-256-CBC encrypted using TEMP_LUKS_KEY so it cannot be read over HTTP
    local secret_file="${token_dir}/.secret_keys.enc"
    install -m 600 /dev/null "${secret_file}"

    printf '%s' "${LUKS_PASSPHRASE}" | TEMP_LUKS_KEY="${TEMP_LUKS_KEY}" openssl enc -aes-256-cbc -pbkdf2 -pass env:TEMP_LUKS_KEY -out "${secret_file}"
    chmod 600 "${secret_file}"

    local allow_tcp="no"
    if [[ "${ALLOW_SSH_FORWARDING:-false}" == "true" ]]; then
        allow_tcp="yes"
    fi

    local allow_users="${ALLOW_USERS:-${USERNAME}}"
    local header_backup_path="${LUKS_HEADER_BACKUP_PATH:-/root/luks-header-backup.img}"

    # Perform template substitution with sed_escape helper (no secrets in postinst.sh!)
    sed \
        -e "s|__USERNAME__|$(sed_escape "${USERNAME}")|g" \
        -e "s|__ALLOW_USERS__|$(sed_escape "${allow_users}")|g" \
        -e "s|__SSH_PORT__|$(sed_escape "${SSH_PORT}")|g" \
        -e "s|__SSH_PUBKEY__|$(sed_escape "${SSH_PUBKEY}")|g" \
        -e "s|__ALLOW_SSH_FORWARDING__|$(sed_escape "${allow_tcp}")|g" \
        -e "s|__HOSTNAME__|$(sed_escape "${HOSTNAME}")|g" \
        -e "s|__INTERFACE__|$(sed_escape "${INTERFACE}")|g" \
        -e "s|__IPV4_ADDRESS__|$(sed_escape "${IPV4_ADDRESS}")|g" \
        -e "s|__IPV4_CIDR__|$(sed_escape "${IPV4_CIDR}")|g" \
        -e "s|__IPV4_NETMASK__|$(sed_escape "${IPV4_NETMASK}")|g" \
        -e "s|__IPV4_GATEWAY__|$(sed_escape "${IPV4_GATEWAY}")|g" \
        -e "s|__IPV6_ADDRESS__|$(sed_escape "${IPV6_ADDRESS:-}")|g" \
        -e "s|__IPV6_PREFIX__|$(sed_escape "${IPV6_PREFIX:-}")|g" \
        -e "s|__IPV6_GATEWAY__|$(sed_escape "${IPV6_GATEWAY:-}")|g" \
        -e "s|__DNS_SERVERS__|$(sed_escape "${DNS_SERVERS}")|g" \
        -e "s|__TIMEZONE__|$(sed_escape "${TIMEZONE}")|g" \
        -e "s|__INITRAMFS_IP__|$(sed_escape "${initramfs_ip}")|g" \
        -e "s|__DISK__|$(sed_escape "${DISK}")|g" \
        -e "s|__INSTALL_TOKEN__|$(sed_escape "${INSTALL_TOKEN}")|g" \
        -e "s|__TEMP_LUKS_KEY__|$(sed_escape "${TEMP_LUKS_KEY}")|g" \
        -e "s|__LUKS_HEADER_BACKUP_PATH__|$(sed_escape "${header_backup_path}")|g" \
        -e "s|__DEBIAN_RELEASE__|$(sed_escape "${DEBIAN_RELEASE:-trixie}")|g" \
        -e "s|__INSTALL_ROLE__|$(sed_escape "${INSTALL_ROLE}")|g" \
        -e "s|__MOUNT_EXTRA_DISKS__|$(sed_escape "${MOUNT_EXTRA_DISKS:-}")|g" \
        -e "s|__EXTRA_DISKS__|$(sed_escape "${EXTRA_DISKS:-}")|g" \
        "${template_file}" > "${output_file}"

    chmod 700 "${output_file}"
    echo "    ✓ Generated: ${output_file}"
    echo ""
}
