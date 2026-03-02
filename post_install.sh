#!/usr/bin/env bash
set -u -o pipefail

# Fedora Post-Install Script (Fedora 43+ / DNF5)
# - Continues if a command fails (best-effort) via `run`
# - Skips some work if already configured/installed where it’s easy to check
#
# Includes:
# - RPM Fusion + codecs + tainted (dvdcss)
# - Terra repo
# - Firmware updates (fwupd)
# - Flathub (system-wide) + Flatpaks (Gear Lever, ONLYOFFICE)
# - VA-API + Intel/AMD tweaks
# - Microsoft fonts (core + Cambria via PowerPoint Viewer)
# - Remove LibreOffice
# - Install btrfs-assistant

# -----------------------------
# Helpers
# -----------------------------
log() { printf "\n==> %s\n" "$*"; }
warn() { printf "WARNING: %s\n" "$*" >&2; }

run() {
  # Run command; if it fails, log and continue.
  "$@"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    warn "Command failed (exit $rc): $*"
  fi
  return 0
}

is_rpm_installed() { rpm -q "$1" >/dev/null 2>&1; }

flatpak_is_installed() {
  # System-wide flatpak check
  local appid="$1"
  flatpak info --system "$appid" >/dev/null 2>&1
}

repo_id_enabled() {
  local repo_id="$1"
  sudo dnf -q repolist --enabled 2>/dev/null | awk '{print $1}' | grep -qx "$repo_id"
}

# -----------------------------
# Sudo + Temp workspace
# -----------------------------
log "Initializing sudo..."
sudo -v || { echo "Sudo failed; cannot continue." >&2; exit 1; }

TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT
log "Using temp workspace: $TMPDIR"

# -----------------------------
# 0) Base tooling + refresh
# -----------------------------
log "Installing base tooling..."
run sudo dnf -y install dnf-plugins-core curl ca-certificates pciutils cabextract fontconfig xorg-x11-font-utils flatpak fwupd

log "Upgrading system..."
run sudo dnf -y upgrade --refresh

# -----------------------------
# 1) Enable RPM Fusion + OpenH264
# -----------------------------
log "Enabling RPM Fusion repositories..."
run sudo dnf -y install \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"

log "Enabling fedora-cisco-openh264 repository..."
run sudo dnf -y config-manager setopt fedora-cisco-openh264.enabled=1

log "Refreshing metadata after repo changes..."
run sudo dnf -y upgrade --refresh

log "Installing RPM Fusion AppStream data..."
run sudo dnf -y install rpmfusion-\*-appstream-data

# -----------------------------
# 2) Multimedia codecs (DNF5 group) + ffmpeg swap
# -----------------------------
log "Swapping ffmpeg-free -> ffmpeg (RPM Fusion)..."
if is_rpm_installed ffmpeg; then
  log "ffmpeg already installed; skipping swap."
else
  run sudo dnf -y swap ffmpeg-free ffmpeg --allowerasing
fi

log "Installing multimedia group (DNF5 syntax)..."
run sudo dnf -y group install multimedia \
  --with-optional \
  --setopt=install_weak_deps=False \
  --exclude=PackageKit-gstreamer-plugin

# -----------------------------
# 3) RPM Fusion tainted (DVD playback)
# -----------------------------
log "Enabling RPM Fusion tainted repositories..."
run sudo dnf -y install rpmfusion-free-release-tainted rpmfusion-nonfree-release-tainted

log "Installing libdvdcss..."
run sudo dnf -y install libdvdcss

# -----------------------------
# 4) Terra repository (Fedora 43+; skip if already enabled)
# -----------------------------
log "Ensuring Terra repository is configured..."
if repo_id_enabled "terra"; then
  log "Terra repo already enabled; skipping."
else
  # If multiple repo files define [terra], keep first.
  MATCHING=()
  for f in /etc/yum.repos.d/*.repo; do
    [[ -f "$f" ]] || continue
    if grep -q '^\[terra\]' "$f"; then
      MATCHING+=("$f")
    fi
  done

  if (( ${#MATCHING[@]} > 1 )); then
    log "Found duplicate [terra] definitions; keeping the first, removing the rest:"
    printf '   keep: %s\n' "${MATCHING[0]}"
    for ((i=1; i<${#MATCHING[@]}; i++)); do
      printf '   remove: %s\n' "${MATCHING[i]}"
      run sudo rm -f "${MATCHING[i]}"
    done
  fi

  log "Adding Terra repo (as requested; uses --nogpgcheck)..."
  run sudo dnf -y install --nogpgcheck \
    --repofrompath "terra,https://repos.fyralabs.com/terra\$releasever" \
    terra-release

  log "Installing Terra multimedia release package..."
  run sudo dnf -y install terra-release-multimedia

  log "Refreshing metadata after Terra..."
  run sudo dnf -y upgrade --refresh
fi

# -----------------------------
# 5) Firmware updates (fwupd) — best effort
# -----------------------------
log "Running firmware updates (fwupd)..."
if command -v fwupdmgr >/dev/null 2>&1; then
  run sudo fwupdmgr refresh --force
  run sudo fwupdmgr update -y
else
  warn "fwupdmgr not found; skipping firmware updates."
fi

# -----------------------------
# 6) Flathub (system-wide) + Flatpaks
# -----------------------------
log "Adding Flathub remote system-wide..."
run sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# -----------------------------
# 7) VA-API / hardware video decoding
# -----------------------------
log "Installing VA-API libraries..."
run sudo dnf -y install ffmpeg-libs libva libva-utils

log "Detecting GPU..."
GPU_INFO="$(lspci -nn | grep -Ei 'vga|3d|display' || true)"
echo "$GPU_INFO"

if echo "$GPU_INFO" | grep -qi "intel"; then
  log "Intel GPU detected: installing Intel media driver..."
  run sudo dnf -y install intel-media-driver libva-intel-driver
fi

if echo "$GPU_INFO" | grep -qiE "amd|advanced micro devices|ati"; then
  log "AMD GPU detected: swapping Mesa VA/VDPAU drivers to *-freeworld..."
  run sudo dnf -y swap mesa-va-drivers mesa-va-drivers-freeworld --allowerasing
  run sudo dnf -y swap mesa-vdpau-drivers mesa-vdpau-drivers-freeworld --allowerasing

  if rpm -q glibc.i686 >/dev/null 2>&1; then
    log "32-bit runtime detected: swapping i686 Mesa VA/VDPAU drivers..."
    run sudo dnf -y swap mesa-va-drivers.i686 mesa-va-drivers-freeworld.i686 --allowerasing
    run sudo dnf -y swap mesa-vdpau-drivers.i686 mesa-vdpau-drivers-freeworld.i686 --allowerasing
  else
    log "No 32-bit runtime detected; skipping i686 swaps."
  fi
fi

# -----------------------------
# 8) Microsoft fonts (Core + Cambria)
# -----------------------------
log "Installing Microsoft Core fonts (msttcore-fonts-installer)..."
CORE_FONTS_PKG="msttcore-fonts-installer"
CORE_FONTS_URL="https://downloads.sourceforge.net/project/mscorefonts2/rpms/msttcore-fonts-installer-2.6-1.noarch.rpm"
CORE_FONTS_RPM="$TMPDIR/msttcore-fonts-installer-2.6-1.noarch.rpm"

if is_rpm_installed "$CORE_FONTS_PKG"; then
  log "Core fonts installer already installed; skipping."
else
  run curl -fL -o "$CORE_FONTS_RPM" "$CORE_FONTS_URL"
  if [[ -f "$CORE_FONTS_RPM" ]]; then
    run sudo rpm -ivh --nodigest --nofiledigest "$CORE_FONTS_RPM"
  else
    warn "Core fonts RPM download failed; skipping core fonts."
  fi
fi

log "Installing Cambria (and other MS fonts) from PowerPoint Viewer..."
MS_FONT_DIR="/usr/local/share/fonts/microsoft"
if ls "$MS_FONT_DIR"/*.{TTF,TTC} >/dev/null 2>&1; then
  log "Microsoft font directory already has fonts; skipping PowerPoint Viewer extraction."
else
  PPV_URL="https://archive.org/download/PowerPointViewer_201801/PowerPointViewer.exe"
  PPV_EXE="$TMPDIR/PowerPointViewer.exe"
  run curl -fsSL -o "$PPV_EXE" "$PPV_URL"

  if [[ -f "$PPV_EXE" ]]; then
    run cabextract -q "$PPV_EXE" -d "$TMPDIR" -F ppviewer.cab
    if [[ -f "$TMPDIR/ppviewer.cab" ]]; then
      run cabextract -q "$TMPDIR/ppviewer.cab" -d "$TMPDIR" -F '*.TTF' -F '*.TTC'
    fi

    run sudo mkdir -p "$MS_FONT_DIR"
    shopt -s nullglob
    FONT_FILES=("$TMPDIR"/*.TTF "$TMPDIR"/*.TTC)
    if (( ${#FONT_FILES[@]} > 0 )); then
      run sudo mv "${FONT_FILES[@]}" "$MS_FONT_DIR/"
      run sudo fc-cache -f -v
    else
      warn "No TTF/TTC extracted; skipping font install."
    fi
    shopt -u nullglob
  else
    warn "PowerPointViewer.exe download failed; skipping Cambria/Office fonts."
  fi
fi

# -----------------------------
# 9) Software changes (easy to extend)
# -----------------------------
log "Removing unwanted software..."
run sudo dnf remove -y libreoffice

log "Installing language packs after dependency removal"
run sudo dnf install -y langpacks-bg langpacks-de langpacks-en

log "Installing desired software..."
run sudo dnf install -y btrfs-assistant

run sudo flatpak install -y flathub it.mijorus.gearlever
run sudo flatpak install -y flathub org.onlyoffice.desktopeditors


# -----------------------------
# 10) Visual Changes
# -----------------------------
run sudo dnf install -y papirus-icon-theme
run kwriteconfig6 --file kdeglobals --group Icons --key Theme Papirus-Dark

# -----------------------------
# 11) Final upgrade pass
# -----------------------------
log "Final system upgrade pass..."
run sudo dnf -y upgrade --refresh

log "Done. Reboot recommended if kernel/system libraries were updated."
