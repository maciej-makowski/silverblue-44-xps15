# Reinstall Guide

Full reinstall of Fedora Silverblue with LUKS encryption and custom image restore.

## Prerequisites

Before reinstalling, ensure you have:

- [ ] Home directory backup on an external drive (`home-backup-YYYY-MM-DD.tar.zst`)
- [ ] Claude Code data backup on an external drive (`claude-backup.tar.zst`)
- [ ] This repo cloned or accessible (contains restore scripts and image config)
- [ ] Fedora Silverblue USB installer (download from https://fedoraproject.org/silverblue/)
- [ ] LUKS passphrase chosen

## Step 1: Install Fedora Silverblue

1. Boot from the Fedora Silverblue USB
2. In the Anaconda installer, select your disk
3. Choose **"Custom"** partitioning
4. Check **"Encrypt my data"** and set a LUKS passphrase
5. Create the partition layout:
   - `/boot/efi` — 600 MB, EFI System Partition
   - `/boot` — 1 GB, ext4, unencrypted (GRUB must read this)
   - LUKS-encrypted volume group with:
     - `/` — 70–100 GB, ext4
     - `/home` — remainder of disk, ext4
     - `swap` — 8–16 GB (optional)
6. Complete the install and reboot

## Step 2: Enrol TPM2 for auto-unlock (optional)

Skip the LUKS password prompt on boot by enrolling the TPM2 chip. Your password remains as a fallback.

Find your LUKS partition:

```bash
lsblk -f | grep crypto_LUKS
```

Enrol TPM2:

```bash
sudo systemd-cryptenroll /dev/<luks-partition> --tpm2-device=auto
```

Reboot to verify it unlocks without a password. If it falls back to password (e.g. after a BIOS update or Secure Boot change), the TPM2 state has changed — re-enrol with:

```bash
sudo systemd-cryptenroll /dev/<luks-partition> --wipe-slot=tpm2 --tpm2-device=auto
```

## Step 3: Rebase to custom image

```bash
rpm-ostree rebase ostree-unverified-registry:ghcr.io/maciej-makowski/silverblue-44-xps15:latest
```

Blacklist nouveau so it doesn't claim the GPU before the NVIDIA driver:

```bash
rpm-ostree kargs --append=rd.driver.blacklist=nouveau --append=modprobe.blacklist=nouveau
```

Reboot:

```bash
systemctl reboot
```

## Step 4: Verify NVIDIA

```bash
nvidia-smi
```

If it shows "couldn't communicate with the NVIDIA driver":
- Check `sudo dmesg | grep nvidia` — if you see "No NVIDIA devices probed", the nouveau blacklist kargs may be missing
- If the CDI spec is stale (container GPU errors):
  ```bash
  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
  ```

## Step 5: Restore home directory

Mount the external drive and extract the backup:

```bash
cd /home
sudo tar xf /run/media/$USER/<drive>/home-backup-YYYY-MM-DD.tar.zst --use-compress-program='zstd -d'
sudo chown -R cfiet:cfiet /home/cfiet
```

## Step 6: Restore Claude Code data

```bash
cd /home/cfiet
tar xf /run/media/$USER/<drive>/claude-backup.tar.zst --use-compress-program='zstd -d'
```

This restores `~/.claude/` (settings, conversations) and `~/.local/share/claude/` (session data).

## Step 7: Restore flatpaks and toolboxes

Clone this repo (or copy from the external drive):

```bash
git clone https://github.com/maciej-makowski/silverblue-44-xps15.git
cd silverblue-44-xps15
./restore/restore.sh
```

## Step 8: Configure toolbox

```bash
toolbox run git config --global user.name "<your name>"
toolbox run git config --global user.email "<your email>"
toolbox run gh auth login
```

## Step 9: Enable automatic updates

```bash
sudo tee /etc/rpm-ostreed.conf <<'EOF'
[Daemon]
AutomaticUpdatePolicy=stage
EOF
sudo systemctl enable --now rpm-ostreed-automatic.timer
```

## Step 10: Enrol signing keys (if Secure Boot)

If you need to rebuild the image locally or the MOK is not enrolled:

```bash
sudo mokutil --import /etc/pki/akmods/certs/public_key.der
```

Reboot and accept the key in the MOK manager.
