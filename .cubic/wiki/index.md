# aadilxgit/vps-setup Wiki

> This directory is machine-managed by cubic. Edit wiki content through [cubic wiki settings](https://www.cubic.dev/wiki/aadilxgit/vps-setup) and custom instructions.

Wiki version: 2
Source commit: 751213ad392f83f3dec21308ba189250545166a9
Source branch: main
Generated: 2026-08-11T07:24:39.583Z

## Contents

### Overview

- [Introduction & Prerequisites](01-sec-overview/01-page-intro.md)
- [Quick Start Guide](01-sec-overview/02-page-quick-start.md)
- [First Boot Checklist](01-sec-overview/03-page-first-boot.md)

### System Architecture

- [High-Level Architecture](02-sec-architecture/01-page-architecture.md)
- [Core Execution Flow (setup.sh)](02-sec-architecture/02-page-setup-flow.md)
- [Kexec & RAMdisk Payload Injection](02-sec-architecture/03-page-kexec-injection.md)
- [Debian Netboot Download & Verification](02-sec-architecture/04-page-netboot-download.md)
- [Temporary HTTP Server Architecture](02-sec-architecture/05-page-http-server.md)

### Core Features

- [Network Auto-Detection](03-sec-core-features/01-page-network-detect.md)
- [Disk & Boot Mode Auto-Detection](03-sec-core-features/02-page-disk-detect.md)
- [Preseed Generation & Templating](03-sec-core-features/03-page-preseed-gen.md)
- [Post-Install Script Generation](03-sec-core-features/04-page-postinst-gen.md)

### Data Management & Storage

- [LUKS Full-Disk Encryption Setup](04-sec-data-management/01-page-luks-encryption.md)
- [Installation Roles](04-sec-data-management/02-page-install-roles.md)
- [Disk Partitioning & LVM Layout](04-sec-data-management/03-page-disk-layout.md)
- [Storage Wipe Modes](04-sec-data-management/04-page-wipe-modes.md)

### Security & Hardening

- [LUKS Key Security Lifecycle](05-sec-security/01-page-key-lifecycle.md)
- [Remote SSH Unlock (Dropbear)](05-sec-security/02-page-remote-unlock.md)
- [SSH Hardening (OpenSSH)](05-sec-security/03-page-ssh-hardening.md)
- [Firewall & Fail2ban Setup](05-sec-security/04-page-firewall-fail2ban.md)
- [Kernel & Filesystem Hardening](05-sec-security/05-page-fs-hardening.md)
- [Unattended Security Upgrades](05-sec-security/06-page-unattended-upgrades.md)
- [Secret Transport & Injection](05-sec-security/07-page-secret-transport.md)

### Configuration

- [Configuration Reference (config.env)](06-sec-configuration/01-page-config-env.md)
- [Dry Run Mode](06-sec-configuration/02-page-dry-run.md)

### Operations & Maintenance

- [LUKS Header Backup & Recovery](07-sec-ops/01-page-header-backup.md)
- [Testing & Validation Checklist](07-sec-ops/02-page-testing-checklist.md)
- [Troubleshooting & Logs](07-sec-ops/03-page-troubleshooting.md)
- [Security Baseline & Auditing](07-sec-ops/04-page-security-baseline.md)
