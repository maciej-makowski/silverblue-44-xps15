# --- Builder stage: compile and sign the NVIDIA kernel module ---
FROM quay.io/fedora/fedora-silverblue:44 AS kmod-builder

# Install RPM Fusion (nonfree needed for akmod-nvidia)
RUN rpm-ostree install \
        https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-44.noarch.rpm \
        https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-44.noarch.rpm \
    && rpm-ostree cleanup -m

# Install akmods toolchain and NVIDIA kmod source
COPY etc/rpm/macros.kmodtool /etc/rpm/macros.kmodtool
RUN rpm-ostree install akmods akmod-nvidia \
    && rpm-ostree cleanup -m \
    || true

# Build the kmod RPM as the akmods user with signing keys
RUN --mount=type=secret,id=signing_pubkey,dst=/tmp/signing_pubkey \
    --mount=type=secret,id=signing_privkey,dst=/tmp/signing_privkey \
    mkdir -p /etc/pki/akmods-keys/certs /etc/pki/akmods-keys/private /tmp/nvidia-kmod \
    && cp /tmp/signing_pubkey /etc/pki/akmods-keys/certs/public_key.der \
    && cp /tmp/signing_privkey /etc/pki/akmods-keys/private/private_key.priv \
    && chmod 644 /etc/pki/akmods-keys/certs/public_key.der \
    && chmod 644 /etc/pki/akmods-keys/private/private_key.priv \
    && chown akmods:akmods /tmp/nvidia-kmod \
    && KERNEL_VERSION=$(ls /usr/src/kernels/ | head -1) \
    && runuser -u akmods -- akmodsbuild \
        --kernels "$KERNEL_VERSION" \
        --outputdir /tmp/nvidia-kmod \
        /usr/src/akmods/nvidia-kmod.latest

# --- Final stage: the actual Silverblue image ---
FROM quay.io/fedora/fedora-silverblue:44

# Install RPM Fusion repositories
RUN rpm-ostree install \
        https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-44.noarch.rpm \
        https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-44.noarch.rpm \
    && rpm-ostree cleanup -m

# Add NVIDIA Container Toolkit upstream repo (Fedora 44 hasn't packaged it yet).
# Strip the sslcacert directive — Silverblue uses /etc/pki/ca-trust/extracted/pem/...
# instead of the path NVIDIA's .repo file points to, and the system default works fine.
RUN curl -sL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
        | sed '/^sslcacert=/d' \
        > /etc/yum.repos.d/nvidia-container-toolkit.repo

# Install layered packages (no akmods/akmod-nvidia — kmod comes from builder)
RUN rpm-ostree install \
        age \
        bats \
        gnome-shell-extension-appindicator \
        gnome-shell-extension-gsconnect \
        gnome-tweaks \
        gstreamer-plugins-espeak \
        gstreamer1-plugin-openh264 \
        gstreamer1-plugins-bad-freeworld \
        gstreamer1-plugins-ugly \
        libavcodec-freeworld \
        nvidia-container-toolkit \
        podlet \
        rclone \
        restic \
        shfmt \
        steam \
        steam-devices \
        stow \
        stow-doc \
        tmux \
        xcb-util-cursor \
        xcb-util-cursor-devel \
        zsh \
    && rpm-ostree cleanup -m

RUN rpm-ostree override remove nano-default-editor \
        --install vim-default-editor \
        --install vim-enhanced \
    && rpm-ostree cleanup -m

# Install NVIDIA driver packages and the pre-built kmod from the builder.
# We use dnf download + rpm because rpm-ostree install triggers the akmods
# scriptlet which fails in a container. The kmod RPM satisfies the
# nvidia-kmod dependency that xorg-x11-drv-nvidia requires.
COPY --from=kmod-builder /tmp/nvidia-kmod /tmp/nvidia-kmod
RUN dnf download --resolve --destdir=/tmp/nvidia-rpms \
        xorg-x11-drv-nvidia \
        xorg-x11-drv-nvidia-cuda \
        nvidia-settings \
        libva-nvidia-driver \
    && rm -f /tmp/nvidia-rpms/kernel-devel*.rpm \
            /tmp/nvidia-rpms/kernel-devel-matched*.rpm \
            /tmp/nvidia-rpms/xorg-x11-drv-nvidia-kmodsrc*.rpm \
    && rpm -ivh --noscripts --nodeps /tmp/nvidia-kmod/*.rpm /tmp/nvidia-rpms/*.rpm \
    && depmod -a "$(ls /lib/modules/ | head -1)" \
    && rm -rf /tmp/nvidia-rpms /tmp/nvidia-kmod \
       /var/cache/libdnf5 /usr/src/kernels

# Copy NVIDIA container support systemd units
COPY etc/systemd/system/nvidia-container-fix.service /etc/systemd/system/nvidia-container-fix.service
COPY etc/systemd/system/nvidia-cdi-generate.service /etc/systemd/system/nvidia-cdi-generate.service
COPY etc/systemd/system/nvidia-cdi-generate.timer /etc/systemd/system/nvidia-cdi-generate.timer
COPY usr/libexec/nvidia-container-fix.sh /usr/libexec/nvidia-container-fix.sh

# Enable the NVIDIA services
RUN chmod +x /usr/libexec/nvidia-container-fix.sh \
    && systemctl enable nvidia-container-fix.service \
    && systemctl enable nvidia-cdi-generate.service \
    && systemctl enable nvidia-cdi-generate.timer
