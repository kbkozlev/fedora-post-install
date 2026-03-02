# Fedora Post-Install Script

Automates a Fedora workstation setup (targeting Fedora 43+ with DNF5) by enabling repositories, installing codecs/drivers/fonts, applying software changes, and adding selected Flatpaks.

## What the Script Does

`post_install.sh` performs these steps in order:

1. Initializes `sudo`, creates a temporary workspace, installs base tooling, and refreshes/upgrades the system.
2. Enables RPM Fusion (free/nonfree) and `fedora-cisco-openh264`.
3. Installs RPM Fusion AppStream metadata.
4. Replaces `ffmpeg-free` with `ffmpeg` (if needed) and installs the `multimedia` group.
5. Enables RPM Fusion tainted repos and installs `libdvdcss`.
6. Configures the Terra repository (skips if already enabled), including `terra-release-multimedia`.
7. Runs firmware updates via `fwupdmgr` (best effort).
8. Adds Flathub system-wide.
9. Installs VA-API stack and applies GPU-specific tuning:
   - Intel: installs Intel media drivers.
   - AMD: swaps Mesa VA/VDPAU drivers to `*-freeworld` variants (including `i686` if present).
10. Installs Microsoft fonts:
   - Core fonts (`msttcore-fonts-installer`).
   - Cambria/Office fonts by extracting from PowerPoint Viewer.
11. Removes/installs software:
   - Removes `libreoffice`.
   - Installs language packs (`bg`, `de`, `en`), `btrfs-assistant`, `papirus-icon-theme`.
   - Installs Flatpaks: Gear Lever and ONLYOFFICE.

## Behavior and Safety Notes

- The script is **best effort**: most commands are run through a helper that logs failures and continues.
- It still exits early if initial `sudo -v` fails.
- Temporary files are created in a `mktemp` directory and cleaned up automatically on exit.
- Terra setup currently uses `dnf --nogpgcheck` as written in the script.
- Some actions are conditionally skipped if already installed/configured.

## Requirements

- Fedora 43+ (DNF5 syntax is used).
- Working internet connection.
- A user with `sudo` privileges.

## Usage

Run directly from GitHub with `curl`:

```bash
curl -fsSL https://raw.githubusercontent.com/kbkozlev/fedora-post-install/master/post_install.sh | bash
```

Or with `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/kbkozlev/fedora-post-install/master/post_install.sh | bash
```

If you prefer running a local copy:

```bash
chmod +x post_install.sh
./post_install.sh
```

## Post-Run

- Reboot is recommended, especially after firmware updates and multimedia/driver changes.
- Verify hardware acceleration with:

```bash
vainfo
```

## Customization

If this is used across multiple machines, common edits are:

- Remove or keep `libreoffice` depending on preference.
- Adjust language packs.
- Add/remove Flatpaks and RPM packages.
- Remove Terra-related steps if you do not want that repository.
