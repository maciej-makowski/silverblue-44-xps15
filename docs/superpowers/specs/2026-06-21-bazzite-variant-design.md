# Bazzite variant for silverblue-44-xps15

**Date:** 2026-06-21
**Status:** Design approved, pending implementation plan

## Goal

Add a parallel **Bazzite** image variant to this repo, built alongside the existing Silverblue image from the same source tree but a separate Containerfile. The Bazzite variant lets the XPS 15 rebase onto Universal Blue's `bazzite-gnome-nvidia:stable` base — picking up its pre-built signed NVIDIA modules, OGC kernel, and gaming stack — while keeping the existing Silverblue image as the stable fallback. Mirrors the dual-variant pattern already established in the sister `silverblue-44-z13` repo.

## Motivation

1. **Test bench** — evaluate whether Bazzite's tuned kernel and userspace replaces anything we currently layer or work around in the Silverblue variant.
2. **Gaming stack** — Bazzite ships gamescope session, Game Mode, MangoHud, etc., natively.
3. **Skip the akmod pipeline** — Bazzite bakes signed NVIDIA modules against its kernel. No multi-stage build, no signing keys, no `kmod-nvidia` scriptlet workaround in the Bazzite path.
4. **Consistency across machines** — the z13 already has a Bazzite variant; aligning xps15 makes cross-machine OS choices easier.

## Non-goals

- Replacing or modifying the existing Silverblue `Containerfile`. It stays as the primary image and the stable fallback.
- Removing the akmod build pipeline. It is still needed for the Silverblue variant.
- Baking in XPS 15 hardware quirk overlays (suspend / lid / GPU switch). None are known today. Add them as later PRs if bring-up surfaces issues.
- Switching the daily-driver default. The user picks at `rpm-ostree rebase` time.

## Design

### New file: `Containerfile.bazzite`

Single-stage build:

```
FROM ghcr.io/ublue-os/bazzite-gnome-nvidia:stable
```

**Layered packages** (`rpm-ostree install --idempotent`):

- Shell / dev: `zsh`, `tmux`, `podlet`, `bats`, `age`, `shfmt`
- Backup / sync: `rclone`, `restic`, `stow`
- Desktop polish: `gnome-shell-extension-appindicator`, `gnome-shell-extension-gsconnect`, `gnome-tweaks`, `xcb-util-cursor`, `xcb-util-cursor-devel`
- Codecs (Fedora-main / Cisco-hosted only): `gstreamer1-plugin-openh264`, `gstreamer-plugins-espeak`

**Editor override** (mirrors Silverblue):

```
rpm-ostree override remove nano-default-editor \
    --install vim-default-editor \
    --install vim-enhanced
```

(Bazzite still ships nano-default-editor, so the same override applies.)

**Finalisation:**

```
rpm-ostree cleanup -m
rpm-ostree cleanup --repomd
ostree container commit
```

### Things deliberately omitted from the Bazzite variant

| Omitted | Reason |
|---|---|
| Multi-stage `kmod-builder` | Bazzite ships pre-built signed NVIDIA modules |
| BuildKit secret mounts (`signing_pubkey`, `signing_privkey`) | No kmod to sign |
| RPM Fusion repos | Bazzite ships its own codec coverage via Bazzite/Terra COPRs; layering RPM Fusion conflicts with newer Mesa |
| `gstreamer1-plugins-bad-freeworld`, `gstreamer1-plugins-ugly`, `libavcodec-freeworld` | Provided by Bazzite's codec stack |
| `xorg-x11-drv-nvidia*`, `nvidia-settings`, `libva-nvidia-driver` | Already in `bazzite-gnome-nvidia` base |
| `nvidia-container-toolkit` repo + package | Already in Bazzite (managed via `ujust`) |
| `nvidia-container-fix.service`, `nvidia-cdi-generate.service`, `nvidia-cdi-generate.timer`, `/usr/libexec/nvidia-container-fix.sh` | Bazzite has equivalent CDI / container-GPU handling baked in. If parity gaps surface during use, re-introduce selectively. |
| `steam-devices` | Already in Bazzite (idempotent install would no-op; omit for clarity) |
| All `etc/` and `usr/` overlays | None of the current overlay files relate to anything other than NVIDIA container support, which Bazzite handles |

### Updated file: `.github/workflows/build.yml`

Convert to a matrix build (modeled on z13's `build.yml`):

```yaml
strategy:
  fail-fast: false
  matrix:
    include:
      - variant: silverblue
        containerfile: Containerfile
        tag_prefix: ''
        needs_signing_keys: true
      - variant: bazzite
        containerfile: Containerfile.bazzite
        tag_prefix: 'bazzite-'
        needs_signing_keys: false
```

- The "Prepare signing keys" and `--secret` flags only run when `matrix.needs_signing_keys == true`. The Bazzite job has no secrets dependency.
- Tags: `:latest` / `:YYYY-MM-DD` (silverblue), `:bazzite-latest` / `:bazzite-YYYY-MM-DD` (bazzite).
- Bump retention from 4 → 8 (4 per variant). Either keep the inline `gh api` prune loop and adapt it to retain per-prefix, or swap to `actions/delete-package-versions@v5` (z13 uses this — simpler, but coarser: retains the newest N regardless of prefix). Decide during implementation; default recommendation is to keep the inline loop and filter per tag prefix so silverblue and bazzite are pruned independently.
- No `schedule:` trigger added — `check-upstream.yml` remains the cadence source.

### Updated file: `.github/workflows/check-upstream.yml`

Extend to poll **both** base images on the same daily 05:00 UTC cron:

- `quay.io/fedora/fedora-silverblue:44`
- `ghcr.io/ublue-os/bazzite-gnome-nvidia:stable`

One cache entry per base (separate cache keys). If **either** digest is new, trigger `build.yml` once. The matrix rebuilds both variants — slightly wasteful for the unchanged side, but layer caching keeps it cheap and avoids plumbing per-variant workflow inputs.

### Updated file: `README.md`

- Add an "Image variants" table (Silverblue / Bazzite, base image, Containerfile, image tag).
- Document the Bazzite rebase command: `rpm-ostree rebase ostree-unverified-registry:ghcr.io/maciej-makowski/silverblue-44-xps15:bazzite-latest`.
- List what is intentionally omitted from the Bazzite variant.
- Cross-reference the z13 repo's Bazzite variant.
- Remove the "weekly" wording — CI is daily-triggered-by-upstream-change.

### Updated file: `REBASE-GUIDE.md`

Add a "Rebasing to the Bazzite variant" section: rebase command, what to expect (different kernel, different baseline packages), how to roll back to the Silverblue variant or stock Silverblue.

### Files NOT touched

- `Containerfile` — unchanged.
- `etc/`, `usr/` — unchanged.
- `restore/` — shared across variants; no edits.
- `REINSTALL-GUIDE.md` — no clean-install changes for now; can be expanded in a follow-up once the Bazzite variant has been daily-driven.

## Testing

1. Local build of `Containerfile.bazzite` via `podman --remote build -f Containerfile.bazzite -t xps15-bazzite:test .` — no secrets needed. Verify success and layer count is reasonable.
2. Push a branch, open PR, confirm both matrix jobs succeed in CI (silverblue with secrets, bazzite without).
3. After merge, verify both tags publish: `:latest` and `:bazzite-latest`.
4. Rebase a spare deployment slot to `:bazzite-latest`, reboot, smoke-test: GPU works (`nvidia-smi`), Steam launches, container GPU passthrough works (`podman run --device nvidia.com/gpu=all …`).
5. Confirm `check-upstream.yml` triggers a rebuild when the Bazzite base digest changes (test by manually invalidating the cache key).

## Open follow-ups (out of scope for this spec)

- If the Bazzite variant proves stable, consider promoting it to `:latest` and demoting Silverblue.
- Hardware-quirk overlays (suspend, lid, GPU switching) only added if observed in daily use.
- Decide whether to host-install gaming overlays (gamescope/mangohud) or keep them in Steam's Flatpak sandbox like the z13 README documents.
