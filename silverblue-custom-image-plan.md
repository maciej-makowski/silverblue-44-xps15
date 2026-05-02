# Fedora Silverblue Custom OCI Image Plan

## Goal

Reproduce the current Fedora Silverblue 44 setup (layered packages, NVIDIA drivers, container GPU support) as a custom OCI container image, built automatically via GitHub Actions and published to GHCR.

---

## Phase 1: Inventory Current System (completed)

Captured the current deployment state:

- **Refspec:** `fedora:fedora/44/x86_64/silverblue`
- **19 layered packages** including NVIDIA drivers, multimedia codecs, zsh, tmux, etc.
- **3 local packages:** rpmfusion-free-release, rpmfusion-nonfree-release, akmods-keys
- **No overrides**
- **3 custom systemd units** for NVIDIA container GPU passthrough
- **akmods signing keys** for Secure Boot kernel module signing

### /etc customizations baked into the image

- NVIDIA container SELinux fix service and CDI generation timer
- akmods signing key path configuration (`macros.kmodtool`)

### /etc customizations NOT baked in (machine-specific)

- Keyboard layout (`X11/xorg.conf.d/00-keyboard.conf`)
- NetworkManager connections
- hostname, fstab, crypttab, machine-id
- SELinux state, akmods certificates

---

## Phase 2: Build the Custom OCI Image (completed)

### Architecture: Multi-stage build

The Containerfile uses a two-stage build to keep the final image clean:

#### Stage 1: `kmod-builder`

Builds the NVIDIA kernel module RPM in a disposable builder container:

1. Installs RPM Fusion repos
2. Installs `akmods` and `akmod-nvidia` via `rpm-ostree install || true` (the akmods post-install scriptlet fails as root — see "NVIDIA akmods workaround" below — but the packages are still extracted)
3. Copies signing keys from BuildKit secret mounts to paths readable by the `akmods` user
4. Detects the image's kernel version from `/usr/src/kernels/`
5. Runs `akmodsbuild` as the `akmods` user to build and sign `kmod-nvidia`
6. Outputs the built RPM to `/tmp/nvidia-kmod/`

This stage is discarded after the build — no build tooling, kernel-devel, or signing keys end up in the final image.

#### Stage 2: Final image

1. Installs RPM Fusion repos
2. Installs non-NVIDIA layered packages via `rpm-ostree install`
3. Copies the pre-built `kmod-nvidia` RPM from the builder stage
4. Downloads NVIDIA driver packages via `dnf download` and installs everything with `rpm --noscripts --nodeps`
5. Cleans up dnf cache and kernel headers (~270 MB saved)
6. Copies and enables NVIDIA container systemd units

### NVIDIA akmods workaround

Building NVIDIA kernel modules in a container requires working around several issues:

1. **`akmods` refuses to run as root.** The `akmod-nvidia` post-install scriptlet calls `akmods`, which rejects root execution. On a live Silverblue system this is fine — the `akmods.service` systemd unit builds the module on next boot as the `akmods` user. In a container there is no reboot, so `rpm-ostree install` treats the scriptlet failure as fatal and rolls back the transaction.

2. **NVIDIA driver packages pull in `akmod-nvidia`.** `xorg-x11-drv-nvidia` requires `nvidia-kmod`, which is provided by `akmod-nvidia`. This means you can't install the driver packages via `rpm-ostree install` without triggering the same scriptlet failure.

3. **`akmodsbuild` detects the host kernel, not the image kernel.** It defaults to `uname -r`, which in a container returns the CI runner's kernel (e.g. `6.17.0-1008-azure`). The `--kernels` flag must be passed with the version from `/usr/src/kernels/`.

4. **Secret mounts are root-owned.** BuildKit `--mount=type=secret` files are read-only and owned by root, but `akmodsbuild` runs as the `akmods` user and needs to read the signing keys. The keys must be copied to accessible paths before building.

**Solution:** Multi-stage build where the builder stage uses `akmodsbuild` (build-only, no install) as the `akmods` user, then the final stage installs the pre-built RPM. This avoids the scriptlet entirely and keeps build tools out of the final image.

### Signing keys

- Stored as base64-encoded GitHub secrets (`AKMODS_PUBKEY`, `AKMODS_PRIVKEY`)
- Injected at build time via `podman build --secret`
- Copied to readable paths in the builder stage, used for module signing, then discarded
- The private key never persists in any image layer
- The public certificate is not needed in the final image either

---

## Phase 3: Automated Rebuilds (completed)

### GitHub Actions workflow (`.github/workflows/build.yml`)

- **Triggers:** Daily at 05:00 UTC, on push to `main`, on pull requests to `main`
- **Build:** Decodes signing keys from secrets, passes them via `--secret` to `podman build`
- **Push:** Only pushes to GHCR on `main` (skipped for PRs)
- **Registry:** `ghcr.io/maciej-makowski/silverblue-44-xps15:latest`

### Repository setup

- **Repo:** `github.com/maciej-makowski/silverblue-44-xps15` (public)
- **Branch protection:** Required status checks (`build` job), 1 review for non-admins, dismiss stale reviews, no force pushes
- **Merge settings:** Squash merge only, auto-delete branches
- **CODEOWNERS:** `* @maciej-makowski`

---

## File Structure

```
silverblue-44-xps15/
├── Containerfile                          # Multi-stage image definition
├── etc/
│   ├── rpm/
│   │   └── macros.kmodtool               # Points akmods to signing key paths
│   └── systemd/system/
│       ├── nvidia-container-fix.service   # SELinux relabeling for /dev/nvidia*
│       ├── nvidia-cdi-generate.service    # CDI spec regeneration
│       └── nvidia-cdi-generate.timer      # Trigger CDI regen on boot + daily
├── opt/
│   └── systemd/
│       └── nvidia-container-fix.sh        # Script called by the fix service
├── .github/
│   ├── workflows/
│   │   └── build.yml                      # CI: build + push to GHCR
│   └── CODEOWNERS
├── CLAUDE.md                              # Project conventions
├── README.md                              # Setup, usage, key management docs
└── .gitignore
```
