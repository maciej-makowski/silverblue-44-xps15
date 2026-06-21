# Rebase Guide

## Before you start

### 1. Pin your current deployment

This prevents the current working deployment from being garbage collected while you experiment:

```bash
sudo ostree admin pin 0
```

Verify it's pinned:

```bash
rpm-ostree status
```

You should see `pinned: yes` on the current deployment.

### 2. Note your current refspec

```
fedora:fedora/44/x86_64/silverblue
```

## Rebase to the custom image

If rebasing from stock Silverblue with RPM Fusion and akmods-keys installed as
local/layered packages, they must be removed since they're now in the base image:

```bash
rpm-ostree rebase ostree-unverified-registry:ghcr.io/maciej-makowski/silverblue-44-xps15:latest \
    --uninstall=rpmfusion-free-release \
    --uninstall=rpmfusion-nonfree-release \
    --uninstall=akmods-keys \
    --uninstall=libva-nvidia-driver-0.0.14-3.fc44.x86_64
systemctl reboot
```

If you don't have those packages layered (e.g. fresh Silverblue install), the simple form works:

```bash
rpm-ostree rebase ostree-unverified-registry:ghcr.io/maciej-makowski/silverblue-44-xps15:latest
systemctl reboot
```

After reboot, verify you're running the custom image:

```bash
rpm-ostree status
```

The origin should show `ostree-unverified-registry:ghcr.io/maciej-makowski/silverblue-44-xps15:latest`.

### Verify NVIDIA driver

```bash
nvidia-smi
```

Should show your GPU model and driver version. If it fails with "couldn't communicate with the NVIDIA driver", the kmod may not have loaded — check `dmesg | grep nvidia`.

### Verify GPU access inside containers

```bash
# If ollama is configured as a systemd container:
systemctl --user status ollama.service
podman logs ollama 2>&1 | grep -i gpu
```

The logs should show the GPU being detected. If the container fails with "cannot stat libEGL_nvidia.so", the CDI spec needs regenerating:

```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
systemctl --user restart ollama.service
```

## Rolling back

### Option A: Select previous deployment at boot

GRUB shows the previous deployment in its menu. Select it to boot into your pinned stock Silverblue deployment.

### Option B: Rollback from a running system

```bash
rpm-ostree rollback
systemctl reboot
```

### Option C: Rebase back to stock Silverblue

```bash
rpm-ostree rebase fedora:fedora/44/x86_64/silverblue
systemctl reboot
```

## After successful testing

Once you're happy the custom image works correctly, unpin the old deployment:

```bash
sudo ostree admin pin --unpin 1
```

(Use `rpm-ostree status` to check which index the pinned deployment is at — it may be `1` or `2` depending on how many deployments exist.)

## Rebasing to the Bazzite variant

Bazzite uses a different base image and a tuned kernel, so it is not just "more packages" on top of Silverblue. Treat the rebase the same way you treated the initial Silverblue rebase: pin the current deployment first, then rebase, then verify.

```bash
sudo ostree admin pin 0
rpm-ostree rebase ostree-unverified-registry:ghcr.io/maciej-makowski/silverblue-44-xps15:bazzite-latest
systemctl reboot
```

If you were previously on the Silverblue variant and have anything layered locally that the Bazzite variant already provides (e.g. RPM Fusion packages, nvidia-container-toolkit, custom akmod packages), uninstall them before or during the rebase:

```bash
rpm-ostree rebase ostree-unverified-registry:ghcr.io/maciej-makowski/silverblue-44-xps15:bazzite-latest \
    --uninstall=rpmfusion-free-release \
    --uninstall=rpmfusion-nonfree-release \
    --uninstall=nvidia-container-toolkit
systemctl reboot
```

### Verify after rebase

```bash
rpm-ostree status      # origin should show :bazzite-latest
nvidia-smi             # GPU should be visible
ujust --list           # Bazzite's ujust shortcuts should be available
```

If `nvidia-smi` fails, check `dmesg | grep nvidia` for module load errors. Bazzite's modules are signed by Universal Blue's key, which Secure Boot does NOT trust by default; you may need to disable Secure Boot or enroll the ublue key in MOK.

## Switching back to the Silverblue variant

```bash
rpm-ostree rebase ostree-unverified-registry:ghcr.io/maciej-makowski/silverblue-44-xps15:latest
systemctl reboot
```

The same caveats about removing variant-specific layered packages apply in reverse.
