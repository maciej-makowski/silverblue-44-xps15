# silverblue-44-xps15

Custom Fedora Silverblue 44 OCI image for Dell XPS 15 with NVIDIA GPU support.

Sister to [`silverblue-44-z13`](https://github.com/maciej-makowski/silverblue-44-z13). Same patterns, different hardware target — NVIDIA dGPU, not AMD/ROCm.

## Image variants

Two images are built from this repo in parallel from the same source tree:

| Variant | Base | Containerfile | Image tag |
|---|---|---|---|
| Silverblue (default) | `quay.io/fedora/fedora-silverblue:44` | `Containerfile` | `ghcr.io/maciej-makowski/silverblue-44-xps15:latest` |
| Bazzite (test bench) | `ghcr.io/ublue-os/bazzite-gnome-nvidia:stable` | `Containerfile.bazzite` | `ghcr.io/maciej-makowski/silverblue-44-xps15:bazzite-latest` |

The Bazzite variant exists to (a) evaluate whether Universal Blue's OGC kernel + Bazzite tuning replaces anything we work around on the Silverblue side, (b) pick up Bazzite's gaming stack (gamescope session, Game Mode, MangoHud) natively, and (c) skip the custom NVIDIA kmod build pipeline by piggybacking on Bazzite's pre-built signed modules.

## What's Included (Silverblue variant)

### Layered Packages

- **NVIDIA drivers:** xorg-x11-drv-nvidia, xorg-x11-drv-nvidia-cuda, nvidia-settings, libva-nvidia-driver, kmod-nvidia (pre-built in a multi-stage builder)
- **NVIDIA container support:** nvidia-container-toolkit
- **Multimedia codecs:** gstreamer1-plugin-openh264, gstreamer1-plugins-bad-freeworld, gstreamer1-plugins-ugly, libavcodec-freeworld, gstreamer-plugins-espeak
- **Desktop:** gnome-shell-extension-appindicator, gnome-shell-extension-gsconnect, gnome-tweaks, xcb-util-cursor, xcb-util-cursor-devel
- **Tools:** zsh, tmux, podlet, rclone, restic, stow, age, bats, shfmt
- **Gaming:** steam-devices
- **Editor:** vim-default-editor + vim-enhanced (replaces nano-default-editor)

### NVIDIA Container GPU Passthrough (Silverblue only)

Custom systemd units are baked into the image:

- **nvidia-container-fix.service** — Relabels `/dev/nvidia*` with `container_file_t` SELinux context on boot so containers can access the GPU
- **nvidia-cdi-generate.service** — Regenerates the NVIDIA CDI spec (`/etc/cdi/nvidia.yaml`) on every boot
- **nvidia-cdi-generate.timer** — Refreshes the CDI spec daily

## What's Included (Bazzite variant)

Same shell/dev/desktop/editor package set as the Silverblue variant, layered on top of `bazzite-gnome-nvidia:stable`.

### Deliberately omitted vs. Silverblue

- **Multi-stage NVIDIA kmod build** — Bazzite ships pre-built signed modules against its OGC kernel
- **`xorg-x11-drv-nvidia*`, `nvidia-settings`, `libva-nvidia-driver`** — already in the Bazzite NVIDIA base
- **`nvidia-container-toolkit` + custom NVIDIA repo** — already in Bazzite (managed via `ujust`)
- **`nvidia-container-fix.service`, `nvidia-cdi-generate.service`, `nvidia-cdi-generate.timer`, `/usr/libexec/nvidia-container-fix.sh`** — Bazzite has equivalent container-GPU handling baked in
- **RPM Fusion repos and the three RPM-Fusion-exclusive codec packages** (`gstreamer1-plugins-bad-freeworld`, `gstreamer1-plugins-ugly`, `libavcodec-freeworld`) — Bazzite provides equivalent codec coverage via its own COPRs; layering RPM Fusion conflicts with Bazzite's newer Mesa
- **`steam-devices`** — already in Bazzite

## Build Architecture

### Silverblue variant

The `Containerfile` uses a **multi-stage build**:

1. **Builder stage (`kmod-builder`)** — Installs akmods toolchain and akmod-nvidia source, then builds and signs the NVIDIA kernel module RPM using `akmodsbuild`. The signing keys are injected via BuildKit secret mounts and never persist in any image layer.

2. **Final stage** — Installs all user-facing packages, copies the pre-built kmod RPM from the builder, installs NVIDIA driver packages, and enables systemd units. No build toolchain, kernel-devel, or akmods in the final image.

This approach is needed because `akmods` refuses to run as root (which is how container builds execute), and `rpm-ostree install` treats the resulting scriptlet failure as fatal. On a live Silverblue system, the kmod is built by the `akmods.service` systemd unit on next boot — in a container image, we do it explicitly in the builder stage instead.

See `silverblue-custom-image-plan.md` for the full technical writeup.

### Bazzite variant

`Containerfile.bazzite` is a single-stage build with no secrets dependency — Bazzite already ships everything NVIDIA-related.

## Usage

### Rebase a Fresh Silverblue Install (Silverblue variant)

```bash
rpm-ostree rebase ostree-unverified-registry:ghcr.io/maciej-makowski/silverblue-44-xps15:latest
systemctl reboot
```

### Rebase to the Bazzite variant

```bash
rpm-ostree rebase ostree-unverified-registry:ghcr.io/maciej-makowski/silverblue-44-xps15:bazzite-latest
systemctl reboot
```

See [REBASE-GUIDE.md](REBASE-GUIDE.md) for caveats when moving between variants and for full rollback procedure.

### Rollback to Stock Silverblue

```bash
rpm-ostree rebase fedora:fedora/44/x86_64/silverblue
systemctl reboot
```

## Building Locally

### Silverblue variant (requires signing keys)

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

### Bazzite variant (no secrets needed)

```bash
podman --remote build -f Containerfile.bazzite -t silverblue-44-xps15:bazzite-latest .
```

## CI

GitHub Actions builds both variants via a single matrix job in `.github/workflows/build.yml` on every push to `main`, every PR, and on `workflow_dispatch`. PR builds do not push.

A daily-scheduled workflow (`.github/workflows/check-upstream.yml`, 05:00 UTC) polls the digests of both base images (`quay.io/fedora/fedora-silverblue:44` and `ghcr.io/ublue-os/bazzite-gnome-nvidia:stable`); if either has changed since the last poll, it triggers `build.yml` to rebuild both variants. Each variant keeps its 4 newest published versions (`:latest` + `:YYYY-MM-DD` plus a couple of older date tags); older ones are deleted automatically.

Silverblue-variant signing keys are stored as GitHub secrets (`AKMODS_PUBKEY`, `AKMODS_PRIVKEY`), base64-encoded. The Bazzite variant uses no secrets.

## Signing Key Management

(Silverblue variant only — Bazzite uses Universal Blue's signed modules.)

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
