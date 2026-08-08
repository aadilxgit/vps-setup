# VPS Setup — Automated Debian Reinstall with LUKS Encryption

Reinstall a VPS with Debian 13 (Trixie) from a running system — fully automated with LUKS full-disk encryption, remote SSH unlock, and comprehensive server hardening.

## Features

- **[LUKS] Full-Disk Encryption** — Passphrase-based; temporary installation keys are removed after setup so no permanent installer key remains
- **[SSH] Remote LUKS Unlock** — SSH into dropbear at boot to type your passphrase
- **[ROLE] Installation Roles** — `standard` (OS disk only) or `storage-vps` (interactive secondary disk handling)
- **[BOOT] Dual Boot Mode Support** — Auto-detects and configures both UEFI and BIOS/Legacy GPT partitioning automatically
- **[AUTO] Auto-Detection** — IPv4, IPv6, gateway, netmask, DNS, interface, root OS disk
- **[SEC] SSH Hardening** — Custom port, key-only auth, root disabled, no passwords, configurable TCP forwarding
- **[FW] UFW Firewall & Fail2ban** — Default deny incoming, SSH jails active
- **[SYS] Kernel & Filesystem Hardening** — sysctl restrictions, auditd, `/tmp` and `/dev/shm` mounted `nodev,nosuid,noexec`
- **[APT] Unattended Upgrades** — Automatic security patches
- **[CFG] One-Time Config** — Edit `config.env` once, reuse across rebuilds
- **[DRY] Dry Run Mode** — Generate and inspect all files without executing

## Prerequisites

- **Root access** on the VPS
- **KVM/full-virtualization** VPS (not OpenVZ/LXC — kexec doesn't work on containers)
- **VNC/IPMI console access** recommended (in case network config fails during install)
- **A running Debian/Ubuntu** system (for the initial kexec boot)

## Installation Roles

Configure `INSTALL_ROLE` in `config.env`:

### 1. Standard VPS Mode (`INSTALL_ROLE="standard"`) [Default]

- Detects **ONLY** the current running OS/root disk (`/`).
- Installs Debian strictly on that disk.
- All secondary disks are **completely ignored** and left untouched.

### 2. Storage VPS Mode (`INSTALL_ROLE="storage-vps"`)

- Detects the OS disk.
- Scans and displays all additional storage disks (`/dev/vdb`, `/dev/nvme1n1`, etc.).
- Prompts interactively for each extra disk:
  1. **Leave untouched** (default)
  2. **Format (ext4) and mount** under `/mnt/<hostname>-vol`
  3. **Manual configuration**
- **No secondary disk is ever modified without explicit user confirmation.**

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/aadilxgit/vps-setup.git /root/vps-setup
cd /root/vps-setup
cp config.env.example config.env
vim config.env    # edit with your details
```

### 2. Edit `config.env`

At minimum, set these fields:

```bash
USERNAME="yourname"
SSH_PORT="2222"
SSH_PUBKEY="ssh-ed25519 AAAA... your@email"
INSTALL_ROLE="standard"  # or "storage-vps"
```

No password is needed — authentication is SSH key only. The user account is created with a locked password and NOPASSWD sudo.

Everything else (network, disk, timezone) is auto-detected with sensible defaults.

### 3. Test with dry run

```bash
sudo ./setup.sh --dry-run
```

This generates all configuration files in `.work/` without downloading anything or executing kexec. Inspect the output:

```bash
cat .work/preseed.cfg    # Debian installer configuration
cat .work/postinst.sh    # Post-install hardening script
```

### 4. Run for real

```bash
sudo ./setup.sh
```

The script will:
1. Auto-detect network and OS root disk
2. Display all settings and partition tree for confirmation
3. Prompt for LUKS passphrase
4. Download Debian netboot files
5. Generate preseed (with temporary random LUKS key) and post-install scripts
6. Start a temporary HTTP server
7. Require typing `YES` to confirm OS disk destruction
8. `kexec` into the Debian installer

### 5. After installation

The installation takes ~10 minutes. When done, the VPS reboots and waits for LUKS unlock.

**To unlock LUKS remotely:**

```bash
# Clear any old host key for this IP (Dropbear generates its own initramfs key)
ssh-keygen -R YOUR_VPS_IP

# Connect to dropbear (port 22) — it auto-runs cryptroot-unlock
ssh root@YOUR_VPS_IP -p 22
# Enter your LUKS passphrase when prompted
```
*Note: Root login is disabled on the main system OpenSSH daemon, but initramfs Dropbear permits a restricted root session solely executing `/bin/cryptroot-unlock`.*

**To log in normally (after LUKS is unlocked):**

```bash
ssh yourname@YOUR_VPS_IP -p 2222
```

## Project Structure

```
vps-setup/
├── config.env.example      # Example configuration template
├── config.env              # Your configuration (copy from example and edit)
├── setup.sh                # Main setup script
├── lib/
│   ├── detect_network.sh   # Auto-detect IPv4/IPv6/gateway/DNS
│   ├── detect_disk.sh      # Auto-detect primary OS disk + secondary disks + boot mode
│   ├── download.sh         # Download Debian netboot kernel + initrd + SHA256 verification
│   ├── generate_preseed.sh # Generate preseed.cfg from template
│   ├── generate_postinst.sh# Generate post-install script from template
│   └── kexec_boot.sh       # HTTP server + kexec execution
├── templates/
│   ├── preseed.cfg.tmpl    # Preseed template (supports BIOS & UEFI recipes)
│   └── postinst.sh.tmpl    # Post-install hardening template
├── .gitignore              # Ignores .work/ and local config.env
└── README.md               # This file
```

## Configuration Reference

### `config.env` Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `INSTALL_ROLE` | | `standard` | `standard` (OS disk only) or `storage-vps` (interactive secondary disks) |
| `USERNAME` | Yes | — | Non-root user with NOPASSWD sudo |
| `SSH_PORT` | | `2222` | Main SSH daemon port |
| `SSH_PUBKEY` | Yes | — | Your SSH public key |
| `HOSTNAME` | | `vps` | System hostname |
| `DOMAIN` | | *(empty)* | Domain name |
| `TIMEZONE` | | `Asia/Kolkata` | Timezone |
| `LOCALE` | | `en_US.UTF-8` | System locale |
| `KEYMAP` | | `us` | Keyboard layout |
| `DEBIAN_RELEASE` | | `trixie` | Debian release name |
| `DEBIAN_MIRROR` | | `https://deb.debian.org/debian` | APT mirror |
| `ALLOW_SSH_FORWARDING` | | `false` | Enable SSH TCP port forwarding (`true`/`false`) |
| `STORAGE_AUTO_MOUNT` | | `false` | Enable secondary disk auto-mount in storage-vps role (`true`/`false`) |
| `DISK` | | *(auto-detect)* | Target OS disk (auto-detects root disk; set only to override) |
| `IPV4_ADDRESS` | | *(auto-detect)* | Static IPv4 address |
| `IPV4_NETMASK` | | *(auto-detect)* | Subnet mask |
| `IPV4_GATEWAY` | | *(auto-detect)* | Default gateway |
| `IPV6_ADDRESS` | | *(auto-detect)* | Static IPv6 address |
| `IPV6_PREFIX` | | *(auto-detect)* | IPv6 prefix length |
| `IPV6_GATEWAY` | | *(auto-detect)* | IPv6 gateway |
| `DNS_SERVERS` | | `1.1.1.1 1.0.0.1` | Space-separated DNS servers (Cloudflare default) |
| `INTERFACE` | | *(auto-detect)* | Network interface name |
| `EXTRA_PACKAGES` | | *(see config)* | Additional packages to install |

## Disk Partitioning & LUKS Key Security

### OS Disk Layout (`DISK`)

| Partition | Size | Type | Encrypted |
|-----------|------|------|-----------|
| EFI ESP (if UEFI) | 512 MB | fat32 | No |
| `/boot` | 512 MB | ext4 | No |
| LUKS container | Remaining | LUKS2 | — |
| └─ `<hostname>-vol/swap` | 1 GB | swap | Yes |
| └─ `<hostname>-vol/root` | Remaining | ext4 (`/`) | Yes |

The LVM Volume Group is named `<hostname>-vol` (e.g., `vps-vol`).

### LUKS Key Security Mechanism

1. `setup.sh` generates a temporary random key (`TEMP_LUKS_KEY`) for automated preseed partitioning.
2. During post-install (`postinst.sh`), the script adds the user's real passphrase to an available LUKS keyslot using `cryptsetup luksAddKey` and verifies that the real passphrase unlocks the volume.
3. The temporary installer key is removed from the LUKS header via `cryptsetup luksRemoveKey` and verified to no longer unlock the volume.
4. Key files are securely shredded with `shred -u`, and log files (`/var/log/vps-postinst.log`, `syslog`) are sanitized.
5. An unencrypted LUKS header backup is generated at `LUKS_HEADER_BACKUP_PATH` (default: `/root/luks-header-backup.img`, mode 600) for off-site disaster recovery.

## First Boot Checklist

After installation completes and the VPS reboots:

- [ ] **Step 1: Remote LUKS Unlock**: `ssh root@YOUR_VPS_IP -p 22` (enter your passphrase)
- [ ] **Step 2: Main SSH Login**: `ssh yourname@YOUR_VPS_IP -p 2222`
- [ ] **Step 3: Verify Reports**: Check `/root/vps-install-summary.txt` and `/root/encryption-report.txt`
- [ ] **Step 4: Off-site Header Backup**: Retrieve header backup via `umask 077 && ssh -p 2222 yourname@YOUR_VPS_IP 'sudo cat /root/luks-header-backup.img' > ./luks-header-backup.img`
- [ ] **Step 5: Audit Baseline**: Check `/root/security-baseline/` for security configuration backups

## Testing & Validation Checklist

Perform the following verification suite prior to deploying into production:

1. **Fresh Single-Disk VPS Install**:
   - Run setup on a single-disk KVM VPS. Verify clean Debian 13 installation and LUKS unlock.
2. **Storage VPS Mode Verification**:
   - Attach a secondary storage disk (e.g. `/dev/sdb`).
   - Run with `INSTALL_ROLE="standard"`: Verify secondary disk is completely ignored.
   - Run with `INSTALL_ROLE="storage-vps"`: Verify script prompts for secondary disk action before modifying.
3. **Wrong LUKS Passphrase Test**:
   - At Dropbear unlock prompt (port 22), type an incorrect passphrase. Verify access is denied and prompt repeats without corrupting the volume.
4. **Reboot & Service Test**:
   - Reboot the server. Verify Dropbear unlocks volume on port 22, systemd boots, and OpenSSH starts on custom port (2222).
   - Run `systemctl status dropbear` inside booted system: Verify Dropbear is inactive in the main OS.
5. **VPS Snapshot Restore Test**:
   - Take a provider disk snapshot, restore to a new instance, and boot. Verify LUKS prompt unlocks the restored instance cleanly.

## Security Notes

- **No passwords**: The user account has a locked password. Authentication is SSH key only. Sudo is configured with NOPASSWD.
- **SSH Hardening & Recovery Port Warning**: Root login disabled on main OpenSSH daemon. Port 22 is intentionally reserved exclusively for pre-boot LUKS unlocking via Dropbear in initramfs (disabled in the main OS). OpenSSH runs on port 2222. Password auth, X11 forwarding, agent forwarding, and tunnels are disabled by default. Access is restricted to `AllowUsers`. TCP forwarding is configurable via `ALLOW_SSH_FORWARDING`.
- **Secret Transport & Single-Install Tokens**: Temporary installation keys exist only during the active installation window. Secrets are stored under a single-use random subpath (`/INSTALL_TOKEN/.secret_keys`) with mode `600` permissions and are shredded immediately after LUKS key rotation.
- **WIPE_MODE Options & SSD Disclaimer**:
  - `WIPE_MODE="fast"` (default): Quick partition table and filesystem removal.
  - `WIPE_MODE="secure"`: Overwrites sectors during installation.
  - *Disclaimer*: `secure` mode attempts overwrite during install, but cannot guarantee physical forensic destruction on virtualized SSD/NVMe storage due to SSD wear leveling, thin provisioning, and provider storage abstraction layers.
- **LUKS Header Backup Safety**: LUKS header backup is generated at `/root/luks-header-backup.img` (mode 600). Move this file off-site and encrypt it before external storage.
- **Post-Install Verification & Baseline**: Automatically generates an installation summary in `/root/vps-install-summary.txt`, a full disk encryption status report in `/root/encryption-report.txt`, and creates an immutable baseline backup of all security configuration files in `/root/security-baseline/`.
- **Unattended Security Updates**: Configured strictly for Debian security patches (`-security`). Normal package and feature upgrades are not automatically applied.
- **Filesystem Security**: `/tmp` and `/dev/shm` mounted with `nodev,nosuid,noexec`.

## License

MIT
