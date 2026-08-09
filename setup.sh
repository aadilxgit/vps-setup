#!/usr/bin/env bash
# =============================================================================
# VPS Setup — Automated Debian Reinstall with LUKS Encryption
# =============================================================================
#
# This script reinstalls a VPS with Debian (Trixie) from a running system
# using kexec + preseed. Features:
#
#   ✓ Full-disk LUKS encryption with passphrase
#   ✓ Remote LUKS unlock via SSH (dropbear-initramfs)
#   ✓ Auto-detection of network (IPv4/IPv6) and disk
#   ✓ SSH hardening (custom port, key-only auth)
#   ✓ UFW firewall + Fail2ban
#   ✓ Unattended security upgrades
#   ✓ System hardening (sysctl, PAM, etc.)
#
# Usage:
#   1. Edit config.env with your details (one-time)
#   2. Run: sudo ./setup.sh
#   3. Confirm settings and enter LUKS passphrase
#   4. Wait for installation (~10 minutes)
#   5. SSH to port 22 to unlock LUKS, then port $SSH_PORT for normal use
#
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Globals
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/.work"
VERSION="1.0.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─────────────────────────────────────────────────────────────────────────────
# Helper Functions
# ─────────────────────────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"; \
                echo -e "${BOLD}${CYAN}  $*${NC}"; \
                echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}\n"; }

banner() {
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                                                          ║"
    echo "║    ██╗   ██╗██████╗ ███████╗    ███████╗███████╗████████╗║"
    echo "║    ██║   ██║██╔══██╗██╔════╝    ██╔════╝██╔════╝╚══██╔══╝║"
    echo "║    ██║   ██║██████╔╝███████╗    ███████╗█████╗     ██║   ║"
    echo "║    ╚██╗ ██╔╝██╔═══╝ ╚════██║    ╚════██║██╔══╝     ██║   ║"
    echo "║     ╚████╔╝ ██║     ███████║    ███████║███████╗   ██║   ║"
    echo "║      ╚═══╝  ╚═╝     ╚══════╝    ╚══════╝╚══════╝   ╚═╝   ║"
    echo "║                                                          ║"
    echo "║    Automated Debian Install with LUKS Encryption  v${VERSION}  ║"
    echo "║                                                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

cleanup() {
    # Securely shred temporary work files (preseed, postinst, keys)
    if [[ "${DRY_RUN:-false}" != true ]] && [[ -d "${WORK_DIR}" ]]; then
        shred -u "${WORK_DIR}"/* 2>/dev/null || rm -rf "${WORK_DIR}"
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight Checks
# ─────────────────────────────────────────────────────────────────────────────
preflight_checks() {
    log_step "Pre-flight Checks"

    # Must be root (unless running dry-run mode)
    if [[ "${EUID}" -ne 0 ]] && [[ "${DRY_RUN:-false}" != true ]]; then
        log_error "This script must be run as root (use sudo)."
        exit 1
    fi

    # Must be running Linux
    if [[ "$(uname -s)" != "Linux" ]]; then
        log_error "This script only runs on Linux."
        exit 1
    fi

    # Architecture check
    local arch
    arch=$(uname -m)
    if [[ "${arch}" != "x86_64" ]]; then
        log_warn "Detected architecture: ${arch}. This script is designed for x86_64 (amd64)."
        log_warn "Netboot files will be downloaded for amd64. Adjust if needed."
    fi

    # Virtualization check (kexec requires KVM/Xen/VMware/Bare-Metal, not LXC/OpenVZ)
    local virt_type="unknown"
    if command -v systemd-detect-virt &>/dev/null; then
        virt_type=$(systemd-detect-virt 2>/dev/null || echo "none")
    fi

    if [[ "${virt_type}" == "lxc" || "${virt_type}" == "openvz" ]]; then
        log_error "Detected container virtualization: '${virt_type}'."
        log_error "kexec requires full virtualization (KVM, Xen, VMware, Hyper-V, or Bare-Metal)."
        log_error "Installation cannot proceed on a container VPS."
        exit 1
    elif [[ "${virt_type}" != "none" && "${virt_type}" != "unknown" ]]; then
        log_ok "Virtualization check passed: ${virt_type}"
    fi

    # Check for required commands (install if missing)
    local missing_pkgs=()
    command -v ip &>/dev/null || missing_pkgs+=("iproute2")
    command -v wget &>/dev/null || missing_pkgs+=("wget")
    command -v python3 &>/dev/null || missing_pkgs+=("python3")
    command -v kexec &>/dev/null || missing_pkgs+=("kexec-tools")

    command -v findmnt &>/dev/null || missing_pkgs+=("util-linux")
    command -v lsblk &>/dev/null || missing_pkgs+=("util-linux")
    command -v numfmt &>/dev/null || missing_pkgs+=("coreutils")
    command -v fuser &>/dev/null || missing_pkgs+=("psmisc")
    command -v sed &>/dev/null || missing_pkgs+=("sed")

    if (( ${#missing_pkgs[@]} > 0 )); then
        local unique_pkgs
        unique_pkgs=$(printf '%s\n' "${missing_pkgs[@]}" | sort -u | tr '\n' ' ')
        if [[ "${EUID}" -eq 0 ]]; then
            log_info "Installing missing dependencies: ${unique_pkgs}"
            apt-get update -qq 2>/dev/null || true
            # shellcheck disable=SC2086
            apt-get install -y -qq ${unique_pkgs} 2>/dev/null || true

            local still_missing=()
            local cmd
            for cmd in ip wget python3 kexec findmnt lsblk numfmt fuser sed; do
                command -v "${cmd}" &>/dev/null || still_missing+=("${cmd}")
            done
            if (( ${#still_missing[@]} > 0 )); then
                log_error "Required commands are still missing: ${still_missing[*]}"
                log_error "Install them manually and run this script again."
                exit 1
            fi
        else
            log_warn "Missing dependencies for live execution: ${unique_pkgs} (skipping install in dry-run mode)"
        fi
    fi

    log_ok "All pre-flight checks passed."
}

# ─────────────────────────────────────────────────────────────────────────────
# Load and Validate Configuration
# ─────────────────────────────────────────────────────────────────────────────
load_config() {
    log_step "Loading Configuration"

    local config_file="${SCRIPT_DIR}/config.env"

    if [[ ! -f "${config_file}" ]]; then
        log_error "Configuration file not found: ${config_file}"
        log_error "Copy config.env.example to config.env and edit it."
        exit 1
    fi

    # shellcheck source=config.env
    source "${config_file}"

    # Validate required fields
    local errors=0

    if [[ -z "${USERNAME:-}" ]] || [[ "${USERNAME}" == "changeme" ]] || ! [[ "${USERNAME}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        log_error "USERNAME is invalid or not set in config.env"
        errors=$((errors + 1))
    fi

    if [[ -z "${SSH_PUBKEY:-}" ]] \
        || [[ "${SSH_PUBKEY}" == *"AAAA..."* ]] \
        || ! [[ "${SSH_PUBKEY}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh\.com)[[:space:]]+[A-Za-z0-9+/]+=*([[:space:]]|$) ]]; then
        log_error "SSH_PUBKEY is not set, is placeholder, or is malformed in config.env"
        errors=$((errors + 1))
    fi

    if [[ -z "${SSH_PORT:-}" ]] \
        || ! [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] \
        || (( SSH_PORT < 1 || SSH_PORT > 65535 )) \
        || (( SSH_PORT == 22 )); then
        log_error "SSH_PORT must be a number from 1 to 65535 and must not be 22 (reserved for dropbear)."
        errors=$((errors + 1))
    fi

    # Set defaults for optional fields
    INSTALL_ROLE="${INSTALL_ROLE:-standard}"
    HOSTNAME="${HOSTNAME:-vps}"
    DOMAIN="${DOMAIN:-}"
    TIMEZONE="${TIMEZONE:-UTC}"
    LOCALE="${LOCALE:-en_US.UTF-8}"
    KEYMAP="${KEYMAP:-us}"
    DEBIAN_RELEASE="${DEBIAN_RELEASE:-trixie}"
    EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"

    # Auto-upgrade known legacy HTTP Debian mirrors to HTTPS
    if [[ "${DEBIAN_MIRROR:-}" == "http://deb.debian.org/debian" ]]; then
        DEBIAN_MIRROR="https://deb.debian.org/debian"
    elif [[ "${DEBIAN_MIRROR:-}" == "http://ftp.debian.org/debian" ]]; then
        DEBIAN_MIRROR="https://ftp.debian.org/debian"
    fi
    DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
    local mirror_valid=true
    if [[ "${DEBIAN_MIRROR}" != https://* ]] || [[ "${DEBIAN_MIRROR}" =~ [[:space:]\?#@] ]]; then
        mirror_valid=false
    else
        local m_clean="${DEBIAN_MIRROR#https://}"
        local m_hp="${m_clean%%/*}"
        local m_host="" m_port=""
        if [[ -z "${m_hp}" ]]; then
            mirror_valid=false
        elif [[ "${m_hp}" == \[*\]* ]]; then
            m_host="${m_hp%%\]*}]"
            local m_rest="${m_hp#*\]}"
            if [[ -n "${m_rest}" ]]; then
                if ! [[ "${m_rest}" == :* ]]; then mirror_valid=false; fi
                m_port="${m_rest#:}"
            fi
        else
            m_host="${m_hp%%:*}"
            if [[ "${m_hp}" == *":"* ]]; then
                m_port="${m_hp#*:}"
            fi
        fi
        if [[ -n "${m_port}" ]]; then
            if ! [[ "${m_port}" =~ ^[0-9]+$ ]] || (( m_port < 1 || m_port > 65535 )); then
                mirror_valid=false;
            fi
        fi
        if ! [[ "${m_host}" =~ ^([a-zA-Z0-9.-]+|\[[0-9a-fA-F:]+\])$ ]]; then
            mirror_valid=false
        fi
    fi
    if [[ "${mirror_valid}" != true ]]; then
        log_error "DEBIAN_MIRROR must be a valid HTTPS URL with a valid hostname authority (got '${DEBIAN_MIRROR}')."
        errors=$((errors + 1))
    fi

    if (( errors > 0 )); then
        log_error "${errors} configuration error(s) found. Please edit config.env."
        exit 1
    fi
    export USERNAME SSH_PORT SSH_PUBKEY INSTALL_ROLE
    export HOSTNAME DOMAIN TIMEZONE LOCALE KEYMAP
    export DEBIAN_RELEASE DEBIAN_MIRROR EXTRA_PACKAGES

    log_ok "Configuration loaded from ${config_file}"
    echo ""
    echo "    Role:       ${INSTALL_ROLE}"
    echo "    User:       ${USERNAME}"
    echo "    SSH Port:   ${SSH_PORT}"
    echo "    SSH Key:    ${SSH_PUBKEY:0:40}..."
    echo "    Hostname:   ${HOSTNAME}"
    echo "    Timezone:   ${TIMEZONE}"
    echo "    Debian:     ${DEBIAN_RELEASE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Prompt for LUKS Passphrase
# ─────────────────────────────────────────────────────────────────────────────
prompt_luks_passphrase() {
    log_step "LUKS Passphrase"

    if [[ "${DRY_RUN:-false}" == true ]] && [[ -z "${LUKS_PASSPHRASE:-}" ]]; then
        log_info "[Dry Run] Setting dummy LUKS passphrase for template generation."
        LUKS_PASSPHRASE="dryrun-test-passphrase-123"
        export LUKS_PASSPHRASE
        log_ok "LUKS passphrase set (dry-run dummy)."
        return 0
    fi

    echo "Enter the passphrase for LUKS full-disk encryption."
    echo "This passphrase will be required to unlock the disk at every boot."
    echo "You can unlock remotely via SSH (dropbear on port 22) or via VPS console."
    echo ""
    echo "Requirements:"
    echo "  - Minimum 8 characters"
    echo "  - Use a mix of upper/lower case, numbers, and symbols"
    echo "  - Do NOT forget this — there is no recovery without it!"
    echo ""

    while true; do
        read -rsp "LUKS Passphrase: " LUKS_PASSPHRASE
        echo ""

        if [[ ${#LUKS_PASSPHRASE} -lt 8 ]]; then
            log_warn "Passphrase too short (minimum 8 characters). Try again."
            continue
        fi

        read -rsp "Confirm LUKS Passphrase: " luks_confirm
        echo ""

        if [[ "${LUKS_PASSPHRASE}" != "${luks_confirm}" ]]; then
            log_warn "Passphrases do not match. Try again."
            continue
        fi

        break
    done

    export LUKS_PASSPHRASE
    log_ok "LUKS passphrase set."
}

# ─────────────────────────────────────────────────────────────────────────────
# Display Summary and Confirm
# ─────────────────────────────────────────────────────────────────────────────
display_summary() {
    log_step "Installation Summary"

    echo -e "${BOLD}"
    echo "┌─────────────────────────────────────────────────────────┐"
    echo "│                Installation Summary                     │"
    echo "├─────────────────────────────────────────────────────────┤"
    printf "│  %-16s  %-34s│\n" "Install Role:" "${INSTALL_ROLE}"
    printf "│  %-16s  %-34s│\n" "Target Disk:" "${DISK}"
    printf "│  %-16s  %-34s│\n" "Volume Group:" "${VG_NAME:-${HOSTNAME}-vol}"
    if [[ "${INSTALL_ROLE}" == "storage-vps" ]]; then
        printf "│  %-16s  %-34s│\n" "Extra Disks:" "${MOUNT_EXTRA_DISKS:-None selected}"
    else
        printf "│  %-16s  %-34s│\n" "Extra Disks:" "Ignored (standard mode)"
    fi
    printf "│  %-16s  %-34s│\n" "Boot Mode:" "${BOOT_MODE}"
    echo "│                                                         │"
    printf "│  %-16s  %-34s│\n" "IPv4:" "${IPV4_ADDRESS}/${IPV4_CIDR}"
    printf "│  %-16s  %-34s│\n" "IPv4 Gateway:" "${IPV4_GATEWAY}"
    if [[ -n "${IPV6_ADDRESS:-}" ]]; then
        printf "│  %-16s  %-34s│\n" "IPv6:" "${IPV6_ADDRESS}/${IPV6_PREFIX}"
        printf "│  %-16s  %-34s│\n" "IPv6 Gateway:" "${IPV6_GATEWAY:-N/A}"
    fi
    printf "│  %-16s  %-34s│\n" "DNS:" "${DNS_SERVERS}"
    printf "│  %-16s  %-34s│\n" "Interface:" "${INTERFACE}"
    echo "│                                                         │"
    echo "│  LUKS Encryption: YES (temporary installer key + user swap)│"
    echo "│  Remote Unlock:   Dropbear SSH on port 22 in initramfs   │"
    echo "│  Firewall:        UFW (port ${SSH_PORT}/tcp allowed)               │"
    echo "│  Fail2ban:        SSH jail active                       │"
    echo "│  Security:        Auditd, sysctl hardening, secure /tmp │"
    echo "└─────────────────────────────────────────────────────────┘"
    echo -e "${NC}"

    local disk_size disk_model disk_serial disk_fstype
    disk_size=$(lsblk -dnbo SIZE "${DISK}" 2>/dev/null | head -n1)
    [[ -n "${disk_size}" ]] && disk_size=$(numfmt --to=iec-i --suffix=B "${disk_size}" 2>/dev/null || echo "${disk_size} bytes")
    disk_model=$(lsblk -dno MODEL "${DISK}" 2>/dev/null | head -n1 | sed 's/^[[:space:]]*//')
    disk_serial=$(lsblk -dno SERIAL "${DISK}" 2>/dev/null | head -n1 | sed 's/^[[:space:]]*//')
    disk_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "ext4")

    echo -e "${RED}${BOLD}⚠️  TARGET DISK CONFIRMATION FINGERPRINT:${NC}"
    echo "  Device:          ${DISK}"
    echo "  Size:            ${disk_size:-unknown}"
    echo "  Model:           ${disk_model:-Generic/Virtual}"
    echo "  Serial/ID:       ${disk_serial:-N/A}"
    echo "  Root Filesystem: ${disk_fstype}"
    echo ""
    echo -e "${RED}${BOLD}WARNING: All existing data on ${DISK} will be PERMANENTLY DESTROYED.${NC}"
    echo ""

    local confirm_text="WIPE ${DISK}"
    read -rp "To confirm disk destruction, type '${confirm_text}' or 'YES': " proceed
    if [[ "${proceed}" != "${confirm_text}" && "${proceed}" != "YES" ]]; then
        log_info "Aborted by user (confirmation did not match '${confirm_text}' or 'YES')."
        exit 0
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Dry Run Mode
# ─────────────────────────────────────────────────────────────────────────────
dry_run_summary() {
    log_step "Dry Run Complete"
    echo "Generated files are in: ${WORK_DIR}/"
    echo ""
    echo "  preseed.cfg   — Debian installer preseed configuration"
    echo "  postinst.sh   — Post-install hardening script"
    echo "  linux         — Debian installer kernel"
    echo "  initrd.gz     — Debian installer initrd"
    echo ""
    echo "To inspect:"
    echo "  cat ${WORK_DIR}/preseed.cfg"
    echo "  cat ${WORK_DIR}/postinst.sh"
    echo ""
    echo "To proceed with actual installation, run without --dry-run."
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
main() {
    local dry_run=false
    local skip_download=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n)
                dry_run=true
                DRY_RUN=true
                export DRY_RUN
                shift
                ;;
            --skip-download)
                skip_download=true
                shift
                ;;
            --help|-h)
                echo "Usage: sudo ./setup.sh [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --dry-run, -n      Generate preseed and postinst files without"
                echo "                     downloading or executing kexec."
                echo "  --skip-download    Skip downloading netboot files (use existing)."
                echo "  --help, -h         Show this help message."
                echo ""
                echo "Configuration: Edit config.env before running this script."
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                echo "Use --help for usage information."
                exit 1
                ;;
        esac
    done

    banner

    # Create work directory with restricted permissions (700)
    mkdir -p "${WORK_DIR}"
    chmod 700 "${WORK_DIR}"

    # Source library scripts
    source "${SCRIPT_DIR}/lib/detect_network.sh"
    source "${SCRIPT_DIR}/lib/detect_disk.sh"
    source "${SCRIPT_DIR}/lib/download.sh"
    source "${SCRIPT_DIR}/lib/generate_preseed.sh"
    source "${SCRIPT_DIR}/lib/generate_postinst.sh"
    source "${SCRIPT_DIR}/lib/kexec_boot.sh"

    # === Step 1: Pre-flight ===
    preflight_checks

    # === Step 2: Load config ===
    load_config

    # === Step 3: Detect network ===
    log_step "Network Detection"
    detect_network
    print_network_config

    # Validate essential network info
    if [[ -z "${IPV4_ADDRESS:-}" ]] || [[ -z "${IPV4_GATEWAY:-}" ]]; then
        log_error "Could not detect IPv4 address or gateway."
        log_error "Please set them manually in config.env."
        exit 1
    fi
    if [[ -z "${INTERFACE:-}" ]]; then
        log_error "Could not detect network interface."
        log_error "Please set INTERFACE in config.env."
        exit 1
    fi

    # === Step 4: Detect disk ===
    log_step "Disk Detection"
    detect_disk
    detect_secondary_disks
    detect_boot_mode
    print_disk_config

    # === Step 5: LUKS passphrase ===
    prompt_luks_passphrase

    # === Step 6: Download netboot files ===
    if [[ "${dry_run}" == true ]]; then
        log_info "[Dry Run] Mocking netboot files in ${WORK_DIR} for dry-run inspection."
        touch "${WORK_DIR}/linux" "${WORK_DIR}/initrd.gz"
    elif [[ "${skip_download}" == false ]]; then
        log_step "Downloading Debian Netboot Files"
        download_netboot_files "${WORK_DIR}"
    else
        log_info "Skipping download (--skip-download). Using existing files."
        if [[ ! -f "${WORK_DIR}/linux" ]] || [[ ! -f "${WORK_DIR}/initrd.gz" ]]; then
            log_error "Netboot files not found in ${WORK_DIR}/. Remove --skip-download."
            exit 1
        fi
    fi

    # === Step 7: Generate preseed ===
    log_step "Generating Preseed Configuration"
    generate_preseed

    # === Step 8: Generate post-install script ===
    log_step "Generating Post-Install Script"
    generate_postinst

    # === Dry run stops here ===
    if [[ "${dry_run}" == true ]]; then
        dry_run_summary
        exit 0
    fi

    # === Step 9: Summary and confirm ===
    display_summary

    # === Step 10: Start Installation ===
    log_step "Starting Installation"
    kexec_boot
}

main "$@"
