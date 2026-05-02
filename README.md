# silverblue-44-xps15

Custom Fedora Silverblue 44 OCI image for Dell XPS 15 with NVIDIA GPU support.

## What's Included

### Layered Packages

- **NVIDIA drivers:** xorg-x11-drv-nvidia, xorg-x11-drv-nvidia-cuda, nvidia-settings, libva-nvidia-driver, kmod-nvidia (pre-built)
- **NVIDIA container support:** nvidia-container-toolkit
- **Multimedia codecs:** gstreamer1-plugin-openh264, gstreamer1-plugins-bad-freeworld, gstreamer1-plugins-ugly, libavcodec-freeworld, gstreamer-plugins-espeak
- **Desktop:** gnome-shell-extension-gsconnect, xcb-util-cursor, xcb-util-cursor-devel
- **Tools:** zsh, tmux, podlet
- **Gaming:** steam-devices

### NVIDIA Container GPU Passthrough

Custom systemd units are baked into the image:

- **nvidia-container-fix.service** — Relabels `/dev/nvidia*` with `container_file_t` SELinux context on boot so containers can access the GPU
- **nvidia-cdi-generate.service** — Regenerates the NVIDIA CDI spec (`/etc/cdi/nvidia.yaml`) on every boot
- **nvidia-cdi-generate.timer** — Refreshes the CDI spec daily

## Build Architecture

The Containerfile uses a **multi-stage build**:

1. **Builder stage (`kmod-builder`)** — Installs akmods toolchain and akmod-nvidia source, then builds and signs the NVIDIA kernel module RPM using `akmodsbuild`. The signing keys are injected via BuildKit secret mounts and never persist in any image layer.

2. **Final stage** — Installs all user-facing packages, copies the pre-built kmod RPM from the builder, installs NVIDIA driver packages, and enables systemd units. No build toolchain, kernel-devel, or akmods in the final image.

This approach is needed because `akmods` refuses to run as root (which is how container builds execute), and `rpm-ostree install` treats the resulting scriptlet failure as fatal. On a live Silverblue system, the kmod is built by the `akmods.service` systemd unit on next boot — in a container image, we do it explicitly in the builder stage instead.

See `silverblue-custom-image-plan.md` for the full technical writeup.

## Usage

### Rebase a Fresh Silverblue Install

```bash
rpm-ostree rebase ostree-unverified-registry:ghcr.io/maciej-makowski/silverblue-44-xps15:latest
systemctl reboot
```

### Rollback to Stock Silverblue

```bash
rpm-ostree rebase fedora:fedora/44/x86_64/silverblue
systemctl reboot
```

## Building Locally

Requires the akmods signing keys accessible on the host:

```bash
podman build \
  --secret id=signing_pubkey,src=/etc/pki/akmods/certs/public_key.der \
  --secret id=signing_privkey,src=/etc/pki/akmods/private/private_key.priv \
  -t silverblue-44-xps15:latest .
```

If running from inside a toolbox:

```bash
# Copy keys to a readable location first
sudo cp /etc/pki/akmods/certs/public_key.der /tmp/signing_pubkey
sudo cp /etc/pki/akmods/private/private_key.priv /tmp/signing_privkey
sudo chmod 644 /tmp/signing_pubkey /tmp/signing_privkey

podman --remote build \
  --secret id=signing_pubkey,src=/tmp/signing_pubkey \
  --secret id=signing_privkey,src=/tmp/signing_privkey \
  -t silverblue-44-xps15:latest .
```

## CI

GitHub Actions rebuilds the image weekly (Sunday 05:00 UTC) and on every push to `main`, then pushes to `ghcr.io/maciej-makowski/silverblue-44-xps15:latest` and a date-tagged version (e.g. `:2026-04-06`). The 4 most recent versions are kept; older ones are automatically deleted. Pull requests trigger a build (without push) to validate changes.

Signing keys are stored as GitHub secrets (`AKMODS_PUBKEY`, `AKMODS_PRIVKEY`), base64-encoded.

## Signing Key Management

The NVIDIA kernel modules must be signed for Secure Boot. Keys are generated on the target machine and enrolled in UEFI via `mokutil`.

### Rotating Keys

1. Generate new keys on the machine: `sudo kmodgenca`
2. Enroll the new public key: `sudo mokutil --import /etc/pki/akmods/certs/public_key.der`
3. Reboot and accept the key in the MOK manager
4. Upload new keys to GitHub secrets:
   ```bash
   sudo base64 -w0 /etc/pki/akmods/certs/public_key.der | gh secret set AKMODS_PUBKEY --repo maciej-makowski/silverblue-44-xps15
   sudo base64 -w0 /etc/pki/akmods/private/private_key.priv | gh secret set AKMODS_PRIVKEY --repo maciej-makowski/silverblue-44-xps15
   ```
5. Trigger a rebuild (push to `main` or manually trigger the workflow)
