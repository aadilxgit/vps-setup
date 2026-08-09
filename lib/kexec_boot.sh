#!/usr/bin/env bash
# =============================================================================
# lib/kexec_boot.sh — Boot into Debian installer via kexec
# =============================================================================
# Starts a temporary HTTP server to serve preseed + postinst, then uses kexec
# to replace the running kernel with the Debian installer.
#
# ⚠️  THIS IS THE POINT OF NO RETURN — the running system is replaced.
# =============================================================================

set -euo pipefail

start_preseed_server() {
    # shellcheck disable=SC2153
    local serve_dir="${WORK_DIR}"
    local port="${PRESEED_PORT:-8080}"

    echo "==> Starting temporary HTTP server on port ${port}..."
    echo "    Serving: ${serve_dir}"

    # Refuse to proceed if the port is already in use
    if fuser "${port}/tcp" &>/dev/null; then
        echo "ERROR: Port ${port}/tcp is already in use. Free it and retry." >&2
        return 1
    fi

    # Start Python HTTP server without changing caller directory and assign PID globally for cleanup trap
    nohup python3 -m http.server "${port}" --directory "${serve_dir}" --bind 0.0.0.0 &>/dev/null &
    HTTP_SERVER_PID=$!
    export HTTP_SERVER_PID

    # Verify it started
    sleep 1
    if ! kill -0 "${HTTP_SERVER_PID}" 2>/dev/null; then
        echo "ERROR: Failed to start HTTP server." >&2
        return 1
    fi

    echo "    ✓ HTTP server running (PID: ${HTTP_SERVER_PID})"
    echo "    Preseed URL: http://${IPV4_ADDRESS}:${port}/preseed.cfg"
    echo "    Postinst URL: http://${IPV4_ADDRESS}:${port}/postinst.sh"
    echo ""

    PRESEED_URL="http://${IPV4_ADDRESS}:${port}/preseed.cfg"
    export PRESEED_URL
}

kexec_boot() {
    local work_dir="${WORK_DIR}"

    echo "==> Preparing kexec boot into Debian installer..."

    # Ensure kexec-tools is installed
    if ! command -v kexec &>/dev/null; then
        echo "    Installing kexec-tools..."
        apt-get update -qq && apt-get install -y -qq kexec-tools
    fi

    local kernel="${work_dir}/linux"
    local initrd="${work_dir}/initrd.gz"

    if [[ ! -f "${kernel}" ]] || [[ ! -f "${initrd}" ]]; then
        echo "ERROR: Kernel or initrd not found in ${work_dir}" >&2
        return 1
    fi

    # Validate required network parameters and PRESEED_URL
    local v
    for v in IPV4_ADDRESS IPV4_NETMASK IPV4_GATEWAY PRESEED_URL; do
        if [[ -z "${!v:-}" ]]; then
            echo "ERROR: ${v} is empty. Cannot build the installer command line." >&2
            return 1
        fi
    done

    # Inject preseed.cfg, postinst.sh, and encrypted secrets directly into initrd.gz
    # This guarantees 100% offline self-contained RAM installation without network HTTP dependencies
    if [[ -f "${serve_dir}/preseed.cfg" && -f "${serve_dir}/postinst.sh" ]]; then
        echo "==> Injecting preseed and post-install configurations into initrd.gz..."
        (
            cd "${serve_dir}"
            find preseed.cfg postinst.sh "${INSTALL_TOKEN:-.}" | cpio -H newc -o 2>/dev/null
        ) | gzip -9 >> "${initrd}"
        echo "    ✓ Configuration payload injected into initrd.gz"
    fi

    local kcmdline=""
    kcmdline+="auto=true "
    kcmdline+="priority=critical "
    kcmdline+="file=/preseed.cfg "
    kcmdline+="preseed/file=/preseed.cfg "
    kcmdline+="interface=auto "
    kcmdline+="netcfg/choose_interface=auto "
    kcmdline+="netcfg/disable_autoconfig=true "
    kcmdline+="netcfg/get_ipaddress=${IPV4_ADDRESS} "
    kcmdline+="netcfg/get_netmask=${IPV4_NETMASK} "
    kcmdline+="netcfg/get_gateway=${IPV4_GATEWAY} "
    kcmdline+="netcfg/get_nameservers=${DNS_SERVERS%% *} "
    kcmdline+="netcfg/confirm_static=true "
    kcmdline+="netcfg/get_hostname=${HOSTNAME} "
    kcmdline+="netcfg/get_domain=${DOMAIN:-local} "
    kcmdline+="locale=${LOCALE} "
    kcmdline+="keymap=${KEYMAP} "
    kcmdline+="console=ttyS0,115200n8 "
    kcmdline+="console=tty0 "

    echo ""
    echo "    Kernel:  ${kernel}"
    echo "    Initrd:  ${initrd}"
    echo "    Cmdline: ${kcmdline}"
    echo ""

    # Load the kernel
    echo "    Loading kernel into memory..."
    kexec -l "${kernel}" --initrd="${initrd}" --append="${kcmdline}" || {
        echo "ERROR: kexec -l failed. Your VPS may not support kexec." >&2
        echo "       This typically happens on container-based virtualization (OpenVZ)." >&2
        return 1
    }

    echo "    ✓ Kernel loaded successfully."
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║           ⚠️  POINT OF NO RETURN ⚠️                       ║"
    echo "║                                                           ║"
    echo "║  The next command will REPLACE the running system with    ║"
    echo "║  the Debian installer. Your SSH session will disconnect.  ║"
    echo "║                                                           ║"
    echo "║  After reboot, connect to the VPS console (VNC/IPMI)     ║"
    echo "║  to monitor the installation, or wait ~10 minutes and    ║"
    echo "║  SSH in to unlock LUKS:                                  ║"
    echo "║                                                           ║"
    echo "║    ssh root@${IPV4_ADDRESS} -p 22                        ║"
    echo "║    (dropbear will prompt for LUKS passphrase)            ║"
    echo "║                                                           ║"
    echo "║  After LUKS is unlocked, SSH into the new system:        ║"
    echo "║                                                           ║"
    echo "║    ssh ${USERNAME}@${IPV4_ADDRESS} -p ${SSH_PORT}        ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    read -rp "Type 'YES' to execute kexec and begin installation: " confirm
    if [[ "${confirm}" != "YES" ]]; then
        echo "Aborted. No changes were made to the running system."
        # Unload the kernel
        kexec -u 2>/dev/null || true
        return 1
    fi

    echo ""
    echo "==> Executing kexec... Goodbye! 🚀"
    echo ""

    # Sync disks before kexec
    sync

    # Execute kexec jump!
    # -f (--force) prevents hanging on hypervisor/systemd driver shutdown handlers
    systemctl kexec 2>/dev/null || kexec -e -f 2>/dev/null || kexec -e
}
