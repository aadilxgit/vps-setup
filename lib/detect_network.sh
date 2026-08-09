#!/usr/bin/env bash
# =============================================================================
# lib/detect_network.sh — Auto-detect network configuration
# =============================================================================
# Detects IPv4/IPv6 addresses, gateways, netmask, DNS servers, and interface
# from the running system using 'ip' commands (iproute2).
#
# Values from config.env take precedence over auto-detected values.
# =============================================================================

set -euo pipefail

detect_network() {
    local detected_iface detected_ipv4 detected_ipv4_cidr detected_ipv4_netmask
    local detected_ipv4_gateway detected_ipv6 detected_ipv6_prefix
    local detected_ipv6_gateway detected_dns

    echo "==> Detecting network configuration..."

    # --- Interface ---
    detected_iface=$(ip -o route show default 2>/dev/null | awk '{print $5}' | head -n1)
    if [[ -z "${detected_iface}" ]]; then
        # Fallback: first non-virtual physical interface that is UP
        detected_iface=$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|veth|br-|tun|tap|virbr|wg|cni|flannel|tailscale)' | head -n1)
    fi
    # Strip @peer suffix (e.g. eth0@if12 → eth0) that appears in veth/container envs
    detected_iface="${detected_iface%%@*}"
    # --- IPv4 ---
    if [[ -n "${detected_iface}" ]]; then
        local ipv4_line
        ipv4_line=$(ip -o -4 addr show dev "${detected_iface}" 2>/dev/null | awk '{print $4}' | head -n1)
        if [[ -n "${ipv4_line}" ]]; then
            detected_ipv4="${ipv4_line%/*}"
            detected_ipv4_cidr="${ipv4_line#*/}"
            detected_ipv4_netmask=$(cidr_to_netmask "${detected_ipv4_cidr}")
        fi
    fi

    detected_ipv4_gateway=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -n1)

    # --- IPv6 ---
    if [[ -n "${detected_iface}" ]]; then
        # Get the first global (non-link-local) IPv6 address
        local ipv6_line
        ipv6_line=$(ip -o -6 addr show dev "${detected_iface}" scope global 2>/dev/null \
            | awk '{print $4}' | head -n1)
        if [[ -n "${ipv6_line}" ]]; then
            detected_ipv6="${ipv6_line%/*}"
            detected_ipv6_prefix="${ipv6_line#*/}"
        fi
    fi

    detected_ipv6_gateway=$(ip -6 route show default 2>/dev/null | awk '{print $3}' | head -n1)

    # --- DNS ---
    if [[ -f /etc/resolv.conf ]]; then
        local raw_dns clean_dns=""
        raw_dns=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}')
        for ns in ${raw_dns}; do
            if [[ "${ns}" != 127.* && "${ns}" != "::1" ]]; then
                clean_dns+="${ns} "
            fi
        done
        detected_dns=$(echo "${clean_dns}" | sed 's/ *$//')
    fi
    # --- Apply: config.env overrides take precedence ---
    INTERFACE="${INTERFACE:-${detected_iface:-}}"
    IPV4_ADDRESS="${IPV4_ADDRESS:-${detected_ipv4:-}}"
    IPV4_NETMASK="${IPV4_NETMASK:-${detected_ipv4_netmask:-}}"
    IPV4_CIDR="${IPV4_CIDR:-${detected_ipv4_cidr:-}}"
    IPV4_GATEWAY="${IPV4_GATEWAY:-${detected_ipv4_gateway:-}}"
    IPV6_ADDRESS="${IPV6_ADDRESS:-${detected_ipv6:-}}"
    IPV6_PREFIX="${IPV6_PREFIX:-${detected_ipv6_prefix:-}}"
    IPV6_GATEWAY="${IPV6_GATEWAY:-${detected_ipv6_gateway:-}}"
    DNS_SERVERS="${DNS_SERVERS:-${detected_dns:-1.1.1.1 1.0.0.1 8.8.8.8}}"
    if [[ -z "${DNS_SERVERS// /}" ]]; then
        DNS_SERVERS="1.1.1.1 1.0.0.1 8.8.8.8"
    fi
    # If user provided netmask as CIDR number in IPV4_NETMASK field, convert first
    if [[ "${IPV4_NETMASK}" =~ ^[0-9]+$ ]] && (( IPV4_NETMASK <= 32 )); then
        IPV4_CIDR="${IPV4_NETMASK}"
        IPV4_NETMASK=$(cidr_to_netmask "${IPV4_CIDR}")
    fi

    # Recalculate CIDR if netmask was set manually but CIDR wasn't
    if [[ -n "${IPV4_NETMASK}" && -z "${IPV4_CIDR}" ]]; then
        IPV4_CIDR=$(netmask_to_cidr "${IPV4_NETMASK}")
    fi
    # And vice versa
    if [[ -n "${IPV4_CIDR}" && -z "${IPV4_NETMASK}" ]]; then
        IPV4_NETMASK=$(cidr_to_netmask "${IPV4_CIDR}")
    fi

    # Export everything
    export INTERFACE IPV4_ADDRESS IPV4_NETMASK IPV4_CIDR IPV4_GATEWAY
    export IPV6_ADDRESS IPV6_PREFIX IPV6_GATEWAY DNS_SERVERS
}

# Convert CIDR prefix length to dotted-decimal netmask
cidr_to_netmask() {
    local cidr=$1
    local mask=""
    local full_octets=$((cidr / 8))
    local partial_bits=$((cidr % 8))

    for ((i = 0; i < 4; i++)); do
        if ((i < full_octets)); then
            mask+="255"
        elif ((i == full_octets)); then
            mask+="$((256 - (1 << (8 - partial_bits))))"
        else
            mask+="0"
        fi
        ((i < 3)) && mask+="."
    done
    echo "${mask}"
}

# Convert dotted-decimal netmask to CIDR prefix length
netmask_to_cidr() {
    local netmask=$1
    local cidr=0
    IFS='.' read -r -a octets <<< "${netmask}"
    for octet in "${octets[@]}"; do
        case ${octet} in
            255) cidr=$((cidr + 8)) ;;
            254) cidr=$((cidr + 7)) ;;
            252) cidr=$((cidr + 6)) ;;
            248) cidr=$((cidr + 5)) ;;
            240) cidr=$((cidr + 4)) ;;
            224) cidr=$((cidr + 3)) ;;
            192) cidr=$((cidr + 2)) ;;
            128) cidr=$((cidr + 1)) ;;
            0)   ;;
            *)   echo "ERROR: Invalid netmask octet: ${octet}" >&2; return 1 ;;
        esac
    done
    echo "${cidr}"
}

# Print detected network configuration
print_network_config() {
    echo ""
    echo "┌─────────────────────────────────────────────────────┐"
    echo "│             Network Configuration                   │"
    echo "├─────────────────────────────────────────────────────┤"
    printf "│  %-16s  %-32s │\n" "Interface:" "${INTERFACE:-NOT DETECTED}"
    echo "│                                                     │"
    printf "│  %-16s  %-32s │\n" "IPv4 Address:" "${IPV4_ADDRESS:-NOT DETECTED}"
    printf "│  %-16s  %-32s │\n" "IPv4 Netmask:" "${IPV4_NETMASK:-NOT DETECTED} (/${IPV4_CIDR:-?})"
    printf "│  %-16s  %-32s │\n" "IPv4 Gateway:" "${IPV4_GATEWAY:-NOT DETECTED}"
    echo "│                                                     │"
    if [[ -n "${IPV6_ADDRESS:-}" ]]; then
        printf "│  %-16s  %-32s │\n" "IPv6 Address:" "${IPV6_ADDRESS}"
        printf "│  %-16s  %-32s │\n" "IPv6 Prefix:" "/${IPV6_PREFIX:-?}"
        printf "│  %-16s  %-32s │\n" "IPv6 Gateway:" "${IPV6_GATEWAY:-NOT DETECTED}"
    else
        printf "│  %-16s  %-32s │\n" "IPv6:" "Not detected / not configured"
    fi
    echo "│                                                     │"
    printf "│  %-16s  %-32s │\n" "DNS Servers:" "${DNS_SERVERS:-NOT DETECTED}"
    echo "└─────────────────────────────────────────────────────┘"
    echo ""
}
