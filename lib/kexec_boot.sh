#!/usr/bin/env bash
# =============================================================================
# lib/kexec_boot.sh — Boot into Debian installer via kexec
# =============================================================================
# Uses kexec to replace the running kernel with the Debian installer.
#
# ⚠️  THIS IS THE POINT OF NO RETURN — the running system is replaced.
# =============================================================================

set -euo pipefail

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

    # Validate required network parameters
    local v
    for v in IPV4_ADDRESS IPV4_NETMASK IPV4_GATEWAY; do
        if [[ -z "${!v:-}" ]]; then
            echo "ERROR: ${v} is empty. Cannot build the installer command line." >&2
            return 1
        fi
    done

    # Inject preseed.cfg, postinst.sh, and encrypted secrets directly into initrd payload
    # This guarantees 100% offline self-contained RAM installation without network HTTP dependencies
    local kexec_initrd="${work_dir}/initrd.kexec.gz"
    cp "${initrd}" "${kexec_initrd}"

    # SECURITY: both preseed.cfg and postinst.sh MUST exist — abort if missing
    if [[ ! -f "${work_dir}/preseed.cfg" ]]; then
        echo "ERROR: preseed.cfg not found in ${work_dir}. Cannot proceed." >&2
        return 1
    fi
    if [[ ! -f "${work_dir}/postinst.sh" ]]; then
        echo "ERROR: postinst.sh not found in ${work_dir}. Cannot proceed." >&2
        return 1
    fi

    # Verify cpio is available (required for initrd injection)
    if ! command -v cpio &>/dev/null; then
        echo "ERROR: 'cpio' command not found. Install it to proceed." >&2
        return 1
    fi

    echo "==> Injecting preseed and post-install configurations into initrd.gz..."
    local inject_rc=0
    (
        cd "${work_dir}"
        if [[ -n "${INSTALL_TOKEN:-}" && -d "${INSTALL_TOKEN}" ]]; then
            find preseed.cfg postinst.sh "${INSTALL_TOKEN}" | cpio -H newc -o 2>/dev/null
        else
            find preseed.cfg postinst.sh | cpio -H newc -o 2>/dev/null
        fi
    ) | gzip -9 >> "${kexec_initrd}" || inject_rc=$?

    if [[ "${inject_rc}" -ne 0 ]]; then
        echo "ERROR: Failed to inject payload into initrd (cpio/gzip pipeline returned ${inject_rc})." >&2
        return 1
    fi

    # Validate the resulting initrd is larger than the original (payload was appended)
    local orig_size kexec_size
    orig_size=$(stat -c%s "${initrd}" 2>/dev/null || echo 0)
    kexec_size=$(stat -c%s "${kexec_initrd}" 2>/dev/null || echo 0)
    if (( kexec_size <= orig_size )); then
        echo "ERROR: initrd payload injection failed — output file is not larger than input." >&2
        return 1
    fi
    echo "    ✓ Configuration payload injected into initrd ($(numfmt --to=iec-i --suffix=B $((kexec_size - orig_size)) 2>/dev/null || echo "$((kexec_size - orig_size)) bytes") added)"

    local kcmdline=""
    # Core automation: auto mode + suppress all non-critical prompts
    kcmdline+="auto=true "
    kcmdline+="priority=critical "
    kcmdline+="DEBCONF_DEBUG=5 "
    # Preseed: injected into initrd, d-i finds it at root
    kcmdline+="preseed/file=/preseed.cfg "
    kcmdline+="file=/preseed.cfg "
    # Network: static configuration matching the current system
    kcmdline+="netcfg/choose_interface=${INTERFACE:-auto} "
    kcmdline+="netcfg/disable_autoconfig=true "
    kcmdline+="netcfg/get_ipaddress=${IPV4_ADDRESS} "
    kcmdline+="netcfg/get_netmask=${IPV4_NETMASK} "
    kcmdline+="netcfg/get_gateway=${IPV4_GATEWAY} "
    kcmdline+="netcfg/get_nameservers=${DNS_SERVERS%% *} "
    kcmdline+="netcfg/confirm_static=true "
    kcmdline+="netcfg/get_hostname=${HOSTNAME} "
    kcmdline+="netcfg/get_domain=${DOMAIN:-local} "
    # Locale and keyboard
    kcmdline+="debian-installer/locale=${LOCALE} "
    kcmdline+="keyboard-configuration/xkb-keymap=${KEYMAP} "
    kcmdline+="locale=${LOCALE} "
    kcmdline+="keymap=${KEYMAP} "
    # Console: support both serial and VGA/VNC console (tty0 MUST be last so VNC is primary)
    kcmdline+="console=ttyS0,115200n8 "
    kcmdline+="console=tty0 "
    # Prevent installer from trying DHCP (wastes time, can override static config)
    kcmdline+="netcfg/use_autoconfig=false "
    kcmdline+="hw-detect/load_firmware=true "
    # Video/Framebuffer: disable KMS handover (bochs-drm) to keep VGA text console active on VNC
    kcmdline+="nomodeset "
    kcmdline+="vga=normal "

    echo ""
    echo "    Kernel:  ${kernel}"
    echo "    Initrd:  ${kexec_initrd}"
    echo "    Cmdline: ${kcmdline}"
    echo ""

    # Load the kernel
    echo "    Loading kernel into memory..."
    kexec -l "${kernel}" --initrd="${kexec_initrd}" --append="${kcmdline}" || {
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
    # -f (--force) bypasses systemd shutdown hangs on cloud hypervisors
    kexec -e -f 2>/dev/null || systemctl kexec 2>/dev/null || kexec -e
}
