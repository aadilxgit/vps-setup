# aadilxgit/vps-setup Wiki

> This directory is machine-managed by cubic. Edit wiki content through [cubic wiki settings](https://www.cubic.dev/wiki/aadilxgit/vps-setup) and custom instructions.

Wiki version: 1
Source commit: 5b6800040cb5e7b0136cc59f12a6a3989f58d791
Source branch: main
Generated: 2026-08-09T05:33:16.811Z

## Contents

### Overview

- [Introduction & Prerequisites](01-section-overview/01-page-intro.md)
- [Quick Start Guide](01-section-overview/02-page-quick-start.md)
- [First Boot Checklist](01-section-overview/03-page-first-boot.md)

### System Architecture

- [High-Level Architecture](02-section-architecture/01-page-architecture.md)
- [Core Execution Flow (setup.sh)](02-section-architecture/02-page-setup-sh.md)
- [Kexec & Temporary HTTP Server](02-section-architecture/03-page-kexec-boot.md)
- [Debian Netboot Download](02-section-architecture/04-page-netboot-dl.md)

### Core Features

- [Network Auto-Detection](03-section-core-features/01-page-network-detect.md)
- [Disk & Boot Mode Auto-Detection](03-section-core-features/02-page-disk-detect.md)
- [Preseed Generation](03-section-core-features/03-page-preseed-gen.md)
- [Post-Install Generation](03-section-core-features/04-page-postinst-gen.md)

### Data Management & Storage

- [LUKS Full-Disk Encryption](04-section-data-management/01-page-luks-encryption.md)
- [LUKS Key Security Lifecycle](04-section-data-management/02-page-luks-key-lifecycle.md)
- [Remote SSH Unlock](04-section-data-management/03-page-ssh-unlock.md)
- [Disk Partitioning & LVM Layout](04-section-data-management/04-page-disk-layout.md)
- [Installation Roles](04-section-data-management/05-page-roles.md)
- [Storage Wipe Modes](04-section-data-management/06-page-wipe-modes.md)

### Security & Hardening

- [SSH Hardening](05-section-security/01-page-ssh-hardening.md)
- [Firewall & Fail2ban Setup](05-section-security/02-page-ufw-fail2ban.md)
- [Kernel & Filesystem Hardening](05-section-security/03-page-fs-hardening.md)
- [Unattended Upgrades](05-section-security/04-page-apt-upgrades.md)

### Configuration

- [Configuration Reference (config.env)](06-section-configuration/01-page-config-env.md)
- [Dry Run Mode](06-section-configuration/02-page-dry-run.md)

### Operations & Maintenance

- [LUKS Header Backup & Recovery](07-section-ops/01-page-header-backup.md)
- [Testing & Validation Checklist](07-section-ops/02-page-testing.md)
- [Troubleshooting & Logs](07-section-ops/03-page-troubleshooting.md)
