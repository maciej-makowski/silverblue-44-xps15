# Bazzite Variant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a parallel Bazzite image variant (`Containerfile.bazzite`) to silverblue-44-xps15, build it in CI alongside the existing Silverblue image, and update upstream polling + docs accordingly. Existing `Containerfile` is not modified.

**Architecture:** Single-stage `FROM ghcr.io/ublue-os/bazzite-gnome-nvidia:stable` layering only shell/dev/desktop packages (no NVIDIA work — Bazzite ships pre-built signed kmods). CI uses a matrix to build both variants from the same workflow; `check-upstream.yml` polls both base digests and triggers rebuild when either changes.

**Tech Stack:** Containerfile (Dockerfile syntax), podman, GitHub Actions (matrix builds, skopeo digest polling), rpm-ostree, ostree.

**Spec:** `docs/superpowers/specs/2026-06-21-bazzite-variant-design.md`

**Branch:** `feat/bazzite-variant-spec` (already created; spec already committed). All implementation tasks commit to this branch.

---

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `Containerfile.bazzite` | Create | Bazzite variant image definition |
| `.github/workflows/build.yml` | Modify | Matrix-build both variants, gate signing-key steps on `matrix.needs_signing_keys` |
| `.github/workflows/check-upstream.yml` | Modify | Poll both base digests; trigger rebuild on any change |
| `README.md` | Modify | Document Bazzite variant, image variant table, omitted-package rationale |
| `REBASE-GUIDE.md` | Modify | Add "Rebasing to the Bazzite variant" section + cross-variant rollback |
| `Containerfile` | NOT TOUCHED | Existing Silverblue image stays as-is |
| `etc/`, `usr/`, `restore/` | NOT TOUCHED | Shared / N/A for Bazzite |

## Testing Approach

This is infrastructure code (Containerfile + GitHub Actions YAML). The "tests" are:
1. **Local podman build** of `Containerfile.bazzite` succeeds (catches package-name typos, layering conflicts, syntax errors).
2. **CI matrix build** succeeds on the PR (catches issues that only surface on the GitHub runner — base image pull, registry auth, tag conflicts).
3. **Post-merge rebase smoke test** on the target machine (out of scope for this plan; tracked as a follow-up in the spec).

No unit tests are written — there is nothing to unit-test in a Containerfile or Actions YAML. The build itself is the test.

---

## Task 1: Create `Containerfile.bazzite`

**Files:**
- Create: `Containerfile.bazzite`

- [ ] **Step 1: Write the Containerfile**

Create `/var/home/cfiet/Documents/Projects/silverblue-44-xps15/Containerfile.bazzite` with this exact content:

```dockerfile
# Bazzite-based variant of silverblue-44-xps15.
#
# Built and published in parallel with `Containerfile` (the Silverblue variant)
# from the same repository. Different image tag suffix:
#   Silverblue: ghcr.io/maciej-makowski/silverblue-44-xps15:latest
#   Bazzite:    ghcr.io/maciej-makowski/silverblue-44-xps15:bazzite-latest
#
# Key differences vs. the Silverblue Containerfile:
#   - No multi-stage kmod build: Bazzite ships pre-built signed NVIDIA modules
#     against its OGC kernel. No BuildKit secrets needed.
#   - No RPM Fusion: Bazzite has its own codec stack via Bazzite/Terra COPRs;
#     layering RPM Fusion conflicts with Bazzite's newer Mesa.
#   - No nvidia-container-toolkit layering and no nvidia-container-fix /
#     nvidia-cdi-generate systemd units: Bazzite handles container GPU passthrough
#     via its own ujust-managed setup.
#   - Drops the three RPM-Fusion-exclusive codec packages
#     (gstreamer1-plugins-bad-freeworld, gstreamer1-plugins-ugly,
#     libavcodec-freeworld). Bazzite provides equivalent coverage.
#   - Drops steam-devices (already in Bazzite).
#
# Everything else (shell/dev tools, desktop polish, vim-as-default-editor
# override) matches the Silverblue variant.

FROM ghcr.io/ublue-os/bazzite-gnome-nvidia:stable

# Layered packages — only Fedora-main / Cisco-hosted things Bazzite doesn't
# already include. `--idempotent` so any future Bazzite-base overlap is a no-op.
RUN rpm-ostree install --idempotent \
        age \
        bats \
        gnome-shell-extension-appindicator \
        gnome-shell-extension-gsconnect \
        gnome-tweaks \
        gstreamer-plugins-espeak \
        gstreamer1-plugin-openh264 \
        podlet \
        rclone \
        restic \
        shfmt \
        stow \
        tmux \
        xcb-util-cursor \
        xcb-util-cursor-devel \
        zsh \
    && rpm-ostree cleanup -m

# Replace nano-default-editor with vim — Bazzite still ships nano as the
# system default editor, same as Fedora Silverblue.
RUN rpm-ostree override remove nano-default-editor \
        --install vim-default-editor \
        --install vim-enhanced \
    && rpm-ostree cleanup -m

# Trigger ostree commit
RUN rpm-ostree cleanup --repomd \
    && ostree container commit
```

- [ ] **Step 2: Local podman build to verify**

From inside the toolbox:

```bash
podman --remote build -f Containerfile.bazzite -t xps15-bazzite:test .
```

Expected: build completes with `Successfully tagged localhost/xps15-bazzite:test`. If it fails on package names (e.g. "Packages not found"), check spelling against `rpm-ostree search <name>` on a running Bazzite system or the bazzite-gnome-nvidia image's `rpm -qa`.

If the build fails because a listed package is already provided by the base, that's a `--idempotent` bug — confirm idempotent semantics in this rpm-ostree version and remove the offending package from the list.

- [ ] **Step 3: Inspect the built image**

```bash
podman --remote inspect xps15-bazzite:test --format '{{.Config.Labels}}' | head -20
podman --remote image tree xps15-bazzite:test | tail -30
```

Expected: bazzite labels visible, image layers reasonable (a handful of new layers on top of the bazzite base).

- [ ] **Step 4: Commit**

```bash
toolbox run git add Containerfile.bazzite
toolbox run git commit -m "feat: add Bazzite variant Containerfile

New parallel image atop ghcr.io/ublue-os/bazzite-gnome-nvidia:stable.
No multi-stage kmod build, no RPM Fusion, no NVIDIA container-toolkit
layering — Bazzite already provides all of those. Same shell/dev/desktop
package set as Silverblue variant.
"
```

---

## Task 2: Convert `build.yml` to matrix build

**Files:**
- Modify: `.github/workflows/build.yml` (full rewrite — change is structural)

- [ ] **Step 1: Replace the workflow file**

Write `/var/home/cfiet/Documents/Projects/silverblue-44-xps15/.github/workflows/build.yml` with:

```yaml
name: Build Silverblue Image

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
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
    steps:
      - uses: actions/checkout@v6

      - name: Log in to GHCR
        run: echo "${{ secrets.GITHUB_TOKEN }}" | podman login ghcr.io -u ${{ github.actor }} --password-stdin

      - name: Prepare signing keys
        if: matrix.needs_signing_keys
        run: |
          mkdir -p /tmp/secrets
          echo "${{ secrets.AKMODS_PUBKEY }}" | base64 -d > /tmp/secrets/signing_pubkey
          echo "${{ secrets.AKMODS_PRIVKEY }}" | base64 -d > /tmp/secrets/signing_privkey

      - name: Set date tag
        id: tag
        run: echo "date=$(date -u +%Y-%m-%d)" >> "$GITHUB_OUTPUT"

      - name: Build image (with signing keys)
        if: matrix.needs_signing_keys
        run: |
          podman build \
            --secret id=signing_pubkey,src=/tmp/secrets/signing_pubkey \
            --secret id=signing_privkey,src=/tmp/secrets/signing_privkey \
            -f ${{ matrix.containerfile }} \
            -t ghcr.io/${{ github.repository }}:${{ matrix.tag_prefix }}latest \
            -t ghcr.io/${{ github.repository }}:${{ matrix.tag_prefix }}${{ steps.tag.outputs.date }} \
            .

      - name: Build image (no signing keys)
        if: '!matrix.needs_signing_keys'
        run: |
          podman build \
            -f ${{ matrix.containerfile }} \
            -t ghcr.io/${{ github.repository }}:${{ matrix.tag_prefix }}latest \
            -t ghcr.io/${{ github.repository }}:${{ matrix.tag_prefix }}${{ steps.tag.outputs.date }} \
            .

      - name: Push image
        if: github.ref == 'refs/heads/main' || github.event_name == 'workflow_dispatch'
        run: |
          podman push ghcr.io/${{ github.repository }}:${{ matrix.tag_prefix }}latest
          podman push ghcr.io/${{ github.repository }}:${{ matrix.tag_prefix }}${{ steps.tag.outputs.date }}

      - name: Clean up old versions for this variant
        if: github.ref == 'refs/heads/main' || github.event_name == 'workflow_dispatch'
        run: |
          PACKAGE="silverblue-44-xps15"
          PREFIX='${{ matrix.tag_prefix }}'
          KEEP=4

          # Fetch all versions, filter to ones whose tags match this variant's prefix.
          # An empty PREFIX is the silverblue variant: keep tags that DON'T start
          # with "bazzite-". A non-empty PREFIX is bazzite: keep tags that DO start
          # with the prefix.
          ALL=$(gh api --paginate \
            user/packages/container/$PACKAGE/versions \
            --jq '.[] | {id: .id, tags: .metadata.container.tags}')

          if [ -z "$PREFIX" ]; then
            VERSIONS=$(echo "$ALL" | jq -r 'select(.tags | length > 0) | select([.tags[] | startswith("bazzite-")] | any | not) | .id')
          else
            VERSIONS=$(echo "$ALL" | jq -r --arg p "$PREFIX" 'select(.tags | length > 0) | select([.tags[] | startswith($p)] | any) | .id')
          fi

          echo "$VERSIONS" | tail -n +$((KEEP + 1)) | while read -r VERSION_ID; do
            [ -z "$VERSION_ID" ] && continue
            echo "Deleting version $VERSION_ID (variant: ${PREFIX:-silverblue})"
            gh api --method DELETE \
              user/packages/container/$PACKAGE/versions/$VERSION_ID
          done
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Clean up secrets
        if: always() && matrix.needs_signing_keys
        run: rm -rf /tmp/secrets
```

Why two separate build steps (`with signing keys` / `no signing keys`) instead of one with conditional `--secret` flags: GitHub Actions doesn't support conditional flag injection within a single `run:` script cleanly without ugly bash conditionals. Two steps gated on `matrix.needs_signing_keys` is clearer and easier to audit.

Why per-variant prune logic: the previous workflow kept the newest 4 of *all* versions. With two variants pushing simultaneously, that would alternately delete the wrong variant. Filtering by tag prefix keeps 4 of each.

- [ ] **Step 2: Lint the YAML**

```bash
toolbox run python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build.yml'))"
```

Expected: no output (silent success). Any traceback means a YAML syntax error — fix and re-run.

- [ ] **Step 3: Commit**

```bash
toolbox run git add .github/workflows/build.yml
toolbox run git commit -m "ci: matrix-build silverblue and bazzite variants

Single job split via strategy matrix; signing-key steps gated on
matrix.needs_signing_keys so the bazzite job needs no secrets.
Prune step now filters by tag prefix so each variant retains
its own 4 newest images independently.
"
```

---

## Task 3: Extend `check-upstream.yml` to poll both bases

**Files:**
- Modify: `.github/workflows/check-upstream.yml` (full rewrite)

- [ ] **Step 1: Replace the workflow file**

Write `/var/home/cfiet/Documents/Projects/silverblue-44-xps15/.github/workflows/check-upstream.yml` with:

```yaml
name: Check Upstream Image

on:
  schedule:
    - cron: '0 5 * * *'
  workflow_dispatch:

jobs:
  check:
    runs-on: ubuntu-latest
    permissions:
      actions: write
    strategy:
      # Run both checks; one triggering a rebuild does not cancel the other.
      fail-fast: false
      matrix:
        include:
          - name: silverblue-base
            image: quay.io/fedora/fedora-silverblue:44
          - name: bazzite-base
            image: ghcr.io/ublue-os/bazzite-gnome-nvidia:stable
    steps:
      - name: Get upstream digest
        id: upstream
        run: |
          DIGEST=$(skopeo inspect docker://${{ matrix.image }} --format '{{.Digest}}')
          echo "digest=$DIGEST" >> "$GITHUB_OUTPUT"
          echo "Upstream ${{ matrix.name }} digest: $DIGEST"

      - name: Restore cached digest
        id: cache
        uses: actions/cache/restore@v5
        with:
          path: /tmp/upstream-digest.txt
          key: upstream-digest-${{ matrix.name }}-${{ steps.upstream.outputs.digest }}

      - name: Check if rebuild needed
        id: check
        run: |
          if [ "${{ steps.cache.outputs.cache-hit }}" == "true" ]; then
            echo "Upstream ${{ matrix.name }} unchanged, skipping rebuild"
            echo "changed=false" >> "$GITHUB_OUTPUT"
          else
            echo "Upstream ${{ matrix.name }} changed, triggering rebuild"
            echo "changed=true" >> "$GITHUB_OUTPUT"
          fi

      - name: Trigger build
        if: steps.check.outputs.changed == 'true'
        run: gh workflow run build.yml --repo ${{ github.repository }}
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Save digest to cache
        if: steps.check.outputs.changed == 'true'
        run: |
          echo "${{ steps.upstream.outputs.digest }}" > /tmp/upstream-digest.txt

      - name: Update cache
        if: steps.check.outputs.changed == 'true'
        uses: actions/cache/save@v5
        with:
          path: /tmp/upstream-digest.txt
          key: upstream-digest-${{ matrix.name }}-${{ steps.upstream.outputs.digest }}
```

Note: the cache key now includes `${{ matrix.name }}` so each base has its own cache entry — Silverblue and Bazzite digests cannot collide. Triggering `build.yml` twice in the same run (if both upstreams changed) is harmless: GitHub coalesces concurrent workflow_dispatch invocations into separate runs, and the matrix build is idempotent.

- [ ] **Step 2: Lint the YAML**

```bash
toolbox run python3 -c "import yaml; yaml.safe_load(open('.github/workflows/check-upstream.yml'))"
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
toolbox run git add .github/workflows/check-upstream.yml
toolbox run git commit -m "ci: poll both silverblue and bazzite base digests

Matrix the check across both base images. Independent cache keys
per base so digests can't collide. Either base changing triggers
build.yml (which rebuilds the full matrix).
"
```

---

## Task 4: Update `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the current file to confirm structure**

```bash
wc -l README.md
```

Expected: the 98-line file documented in the spec exploration.

- [ ] **Step 2: Rewrite `README.md` with variant documentation**

Replace the entire file `/var/home/cfiet/Documents/Projects/silverblue-44-xps15/README.md` with:

```markdown
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
```

- [ ] **Step 3: Commit**

```bash
toolbox run git add README.md
toolbox run git commit -m "docs: document Bazzite variant in README

Add image variant table, per-variant package lists, separate rebase
and local-build instructions, updated CI description (daily upstream
poll for both bases, per-variant retention).
"
```

---

## Task 5: Update `REBASE-GUIDE.md`

**Files:**
- Modify: `REBASE-GUIDE.md`

- [ ] **Step 1: Append the Bazzite section**

Edit `/var/home/cfiet/Documents/Projects/silverblue-44-xps15/REBASE-GUIDE.md` and **append** the following section to the end of the file (after the existing "After successful testing" section):

```markdown

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
```

(The leading blank line before `## Rebasing to the Bazzite variant` keeps the existing markdown structure intact.)

- [ ] **Step 2: Commit**

```bash
toolbox run git add REBASE-GUIDE.md
toolbox run git commit -m "docs: add Bazzite rebase + variant-switch instructions

Same pin-first / rebase / verify pattern as the Silverblue rebase.
Calls out the Secure Boot consideration (Bazzite's modules are
signed by Universal Blue's key, not ours).
"
```

---

## Task 6: Push branch and open PR

- [ ] **Step 1: Push**

```bash
toolbox run git push -u origin feat/bazzite-variant-spec
```

- [ ] **Step 2: Open the PR**

```bash
toolbox run gh pr create --title "Add Bazzite image variant" --body "$(cat <<'EOF'
## Summary
- New parallel `Containerfile.bazzite` atop `ghcr.io/ublue-os/bazzite-gnome-nvidia:stable`. Existing `Containerfile` is not modified.
- CI `build.yml` converted to a matrix build (silverblue + bazzite). Signing-key steps gated on `matrix.needs_signing_keys` so the Bazzite job needs no secrets. Pruning filters by tag prefix so each variant retains its own 4 newest images.
- CI `check-upstream.yml` polls both base digests daily; either changing triggers a full matrix rebuild.
- README and REBASE-GUIDE updated with variant table, per-variant package rationale, rebase commands, and the Bazzite Secure Boot consideration.

Design spec: `docs/superpowers/specs/2026-06-21-bazzite-variant-design.md`
Implementation plan: `docs/superpowers/plans/2026-06-21-bazzite-variant.md`

## Test plan
- [ ] Both matrix jobs (silverblue, bazzite) succeed on this PR
- [ ] After merge, both `:latest` and `:bazzite-latest` tags appear in GHCR
- [ ] Manual smoke test: rebase a spare deployment slot to `:bazzite-latest`, reboot, confirm `nvidia-smi`, Steam, and container GPU passthrough work

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected output: a PR URL on stdout. Report the URL back to the user.

Note: per `~/.claude/CLAUDE.md` global preferences, do **not** enable auto-merge and do **not** merge the PR. The user reviews and merges externally.

---

## Self-Review Checklist (already run)

- **Spec coverage:** Every spec section maps to a task — Containerfile (T1), build.yml matrix (T2), check-upstream dual poll (T3), README (T4), REBASE-GUIDE (T5). Per-variant retention (spec: "decide during implementation; default recommendation is to keep the inline loop and filter per tag prefix") implemented as the recommended approach in T2.
- **Placeholder scan:** No TBD / TODO / "handle edge cases" / "similar to" placeholders.
- **Type / name consistency:** Image tag prefix is `bazzite-` everywhere (workflow matrix, README table, REBASE-GUIDE command). Base image identifier `ghcr.io/ublue-os/bazzite-gnome-nvidia:stable` is consistent across spec, Containerfile, build matrix, upstream check, README.
- **Scope:** Single feature, six discrete tasks, ~30 min total work. No decomposition needed.
