---
title: "LUKS Key Security Lifecycle"
wiki_page_id: "page-luks-key-lifecycle"
---

<details>
<summary>Relevant source files</summary>

The following files were used as context for generating this wiki page:

- [README.md](README.md)
- [setup.sh](setup.sh)
- [lib/generate_preseed.sh](lib/generate_preseed.sh)
- [lib/generate_postinst.sh](lib/generate_postinst.sh)
- [lib/kexec_boot.sh](lib/kexec_boot.sh)
- [lib/detect_disk.sh](lib/detect_disk.sh)
</details>

# LUKS Key Security Lifecycle

The LUKS Key Security Lifecycle within the `vps-setup` project governs the secure generation, utilization, rotation, and disposal of encryption keys during an automated Debian installation. The system ensures that no permanent installer keys remain on the disk post-setup, transitioning from a temporary, automated installation key to a user-defined passphrase.

This lifecycle is critical for maintaining the integrity of the Full-Disk Encryption (FDE) while allowing for a fully unattended installation via `preseed` and `kexec`. The process encompasses initial environment preparation, secure secret transport, post-installation key rotation, and final cleanup of sensitive artifacts.
Sources: [README.md:9-11](README.md#L9-L11), [README.md:144-152](README.md#L144-L152), [setup.sh:319-328](setup.sh#L319-L328)

## Key Generation and Transport

The lifecycle begins with the generation of two distinct secrets: a user-provided passphrase and a system-generated temporary key. These are handled with restricted permissions to prevent unauthorized access.

### Temporary Installation Key (`TEMP_LUKS_KEY`)
A 32-byte random hex string is generated using `openssl` to serve as the `TEMP_LUKS_KEY`. This key is used by the Debian installer's `partman` to automate the creation of the LUKS container without requiring manual interaction.
Sources: [lib/generate_preseed.sh:28-29](lib/generate_preseed.sh#L28-L29), [README.md:145](README.md#L145)

### Secret Transport via Encrypted Payload
To securely pass the user's permanent passphrase to the post-installation environment, the script creates a single-use installation token and an encrypted payload.

1.  **Installation Token**: A 16-byte random hex string (`INSTALL_TOKEN`) defines a unique subpath in the temporary HTTP server.
2.  **Encrypted Payload**: The `LUKS_PASSPHRASE` is encrypted using `openssl` with `AES-256-CBC` and `PBKDF2`, using the `TEMP_LUKS_KEY` as the encryption password. This ensures that even if the transport file is intercepted, it cannot be decrypted without the installer key already present in the preseed.
Sources: [lib/generate_postinst.sh:32-47](lib/generate_postinst.sh#L32-L47)

```mermaid
flowchart TD
    subgraph Host_System[Running Host System]
        A[User Input: LUKS_PASSPHRASE]
        B[Generate: TEMP_LUKS_KEY]
        C[Generate: INSTALL_TOKEN]
        A & B --> D[Encrypt Passphrase with TEMP_LUKS_KEY]
        D --> E[.secret_keys.enc]
        C --> F[Create Restricted Path]
    end
    subgraph Transport[HTTP Transport]
        E --> G[Served via Python HTTP Server]
    end
    Sources: [lib/generate_postinst.sh](lib/generate_postinst.sh), [lib/kexec_boot.sh](lib/kexec_boot.sh)
```

## Post-Installation Key Rotation

The `postinst.sh` script, executed within the new system context, performs the critical transition from the temporary installer key to the permanent user passphrase.

### Rotation Logic
The rotation follows a strict sequence to ensure the volume remains accessible and secure:
1.  **Decryption**: The script retrieves `.secret_keys.enc` and decrypts the user passphrase using the `TEMP_LUKS_KEY`.
2.  **Addition**: The user's real passphrase is added to a new LUKS keyslot using `cryptsetup luksAddKey`.
3.  **Verification**: The system verifies that the new passphrase successfully unlocks the volume.
4.  **Removal**: The `TEMP_LUKS_KEY` is removed from the LUKS header via `cryptsetup luksRemoveKey`.
Sources: [README.md:145-149](README.md#L145-L149), [lib/generate_postinst.sh:75-76](lib/generate_postinst.sh#L75-L76)

### Lifecycle Stages Summary

| Stage | Component | Action | Security Measure |
| :--- | :--- | :--- | :--- |
| **Generation** | `setup.sh` | Generates `TEMP_LUKS_KEY` | 32-byte random hex string |
| **Transport** | `lib/kexec_boot.sh` | Starts HTTP server | Single-use `INSTALL_TOKEN` path |
| **Installation** | `preseed.cfg` | Partitions disk with `TEMP_LUKS_KEY` | Key exists only in memory/preseed |
| **Rotation** | `postinst.sh` | `luksAddKey` user passphrase | Verification before old key removal |
| **Disposal** | `cleanup()` | `shred -u` of work files | Secure deletion of temp keys/preseed |
Sources: [README.md:144-152](README.md#L144-L152), [setup.sh:65-72](setup.sh#L65-L72), [lib/generate_preseed.sh:28-29](lib/generate_preseed.sh#L28-L29), [lib/generate_postinst.sh:32-47](lib/generate_postinst.sh#L32-L47)

## Secure Disposal and Cleanup

Post-installation security relies on the absolute removal of all temporary secrets and sensitive configuration files.

*  **Work Directory Disposal**: The `.work` directory, which contains the `preseed.cfg` (containing the `TEMP_LUKS_KEY`) and `postinst.sh`, is securely shredded. The script uses `shred -u` to overwrite and delete these files.
*  **Memory and Token Cleanup**: The temporary HTTP server is terminated, and the `INSTALL_TOKEN` subpath is removed.
*  **Log Sanitization**: Installation logs such as `/var/log/vps-postinst.log` and the system `syslog` are sanitized to ensure no trace of the rotation process remains.
Sources: [setup.sh:65-72](setup.sh#L65-L72), [README.md:150](README.md#L150)

## Recovery and Verification

As a final step in the lifecycle, the system generates artifacts for disaster recovery and security auditing.

### LUKS Header Backup
An unencrypted backup of the LUKS header is generated at `/root/luks-header-backup.img` with `600` permissions. This allows the user to recover the volume if the header on the physical disk is corrupted.
Sources: [README.md:152](README.md#L152), [lib/generate_postinst.sh:78](lib/generate_postinst.sh#L78)

### Security Reporting
The system generates a `vps-install-summary.txt` and an `encryption-report.txt` in the root directory. These files provide the user with immediate confirmation of the encryption status and the successful completion of the key rotation.
Sources: [README.md:162](README.md#L162), [README.md:195](README.md#L195)

```mermaid
sequenceDiagram
    participant S as setup.sh
    participant I as Debian Installer
    participant P as postinst.sh
    participant D as Disk LUKS Header

    S->>S: Generate TEMP_LUKS_KEY
    S->>I: Provide TEMP_LUKS_KEY (via Preseed)
    I->>D: Format with TEMP_LUKS_KEY (Keyslot 0)
    P->>P: Decrypt User Passphrase
    P->>D: Add User Passphrase (Keyslot 1)
    P->>D: Verify User Passphrase
    P->>D: Remove TEMP_LUKS_KEY (Keyslot 0)
    P->>P: Shred Temporary Files
    Sources: [README.md:144-152](README.md#L144-L152), [setup.sh:319-328](setup.sh#L319-L328)
```

The LUKS Key Security Lifecycle ensures a high-entropy, automated setup while maintaining a strict "no-leftover-secrets" policy, providing a secure foundation for the hardened VPS environment.
Sources: [README.md:204-209](README.md#L204-L209)
