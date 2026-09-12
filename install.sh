#!/bin/bash
# Installs a patched libfprint for the ELAN7001 SPI fingerprint sensor on the
# ASUS X510UNR (and probably other laptops with the same ACPI ID).
#
# Read README.md first. This script installs the build deps and fprintd,
# binds the sensor's SPI device to spidev since the kernel has no driver for
# it, builds libfprint from source with one small patch applied, and installs
# it over the pacman-managed copy (the original gets backed up, not deleted).
#
# Arch based distros only, since it shells out to pacman. Tested on Omarchy.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBFPRINT_TAG="${LIBFPRINT_TAG:-v1.94.100}"
BUILD_DIR="${BUILD_DIR:-$HOME/.cache/elan7001-fprint-build}"
BACKUP_DIR="/root/libfprint-backup"

require_root_helper() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

echo "==> Checking hardware (ELAN7001/ELAN70A1 ACPI device present?)"
if ! find /sys/bus/acpi/devices -maxdepth 1 \( -iname "ELAN7001*" -o -iname "ELAN70A1*" \) 2>/dev/null | grep -q .; then
  echo "No ELAN7001/ELAN70A1 ACPI device found on this system."
  echo "This script is specifically for that sensor (SPI-connected ELAN fingerprint reader)."
  echo "Check with: find /sys/bus/spi/devices -maxdepth 1"
  exit 1
fi
echo "    found."

echo "==> Installing build dependencies + fprintd/libfprint"
require_root_helper pacman -S --needed --noconfirm \
  git cmake meson ninja base-devel glib2-devel \
  libgusb libgudev pixman nss cairo \
  fprintd libfprint

echo "==> Setting up persistent udev rule + spidev module load"
require_root_helper install -Dm644 "$REPO_DIR/udev/99-elan-spi.rules" /etc/udev/rules.d/99-elan-spi.rules
require_root_helper install -Dm644 "$REPO_DIR/modules-load.d/spidev.conf" /etc/modules-load.d/spidev.conf
require_root_helper sh -c 'modprobe spidev; udevadm control --reload-rules; udevadm trigger'

echo "==> Fetching libfprint $LIBFPRINT_TAG"
mkdir -p "$BUILD_DIR"
if [[ ! -d "$BUILD_DIR/libfprint" ]]; then
  git clone --depth 200 https://gitlab.freedesktop.org/libfprint/libfprint.git "$BUILD_DIR/libfprint"
fi
cd "$BUILD_DIR/libfprint"
git fetch --tags origin "$LIBFPRINT_TAG" 2>/dev/null || true
git checkout "$LIBFPRINT_TAG"
git apply --check "$REPO_DIR/patches/0001-lower-bz3-threshold-for-eFSA96SA-and-fix-meson-tests.patch"
git apply "$REPO_DIR/patches/0001-lower-bz3-threshold-for-eFSA96SA-and-fix-meson-tests.patch"

echo "==> Building (introspection disabled -- not needed to run as a system library,"
echo "    and avoids requiring g-ir-scanner which many systems don't have installed)"
rm -rf builddir
meson setup builddir --prefix=/usr --libdir=lib \
  -Ddrivers=all -Dudev_rules_dir=/usr/lib/udev/rules.d \
  -Dintrospection=false -Ddoc=false
ninja -C builddir

echo "==> Backing up the pacman-managed libfprint (kept at $BACKUP_DIR)"
require_root_helper mkdir -p "$BACKUP_DIR"
require_root_helper sh -c "
  set -e
  if [[ ! -f '$BACKUP_DIR/libfprint-2.so.2.0.0.orig-pacman' ]]; then
    cp /usr/lib/libfprint-2.so.2.0.0 '$BACKUP_DIR/libfprint-2.so.2.0.0.orig-pacman'
  fi
  cp '$BUILD_DIR/libfprint/builddir/libfprint/libfprint-2.so.2.0.0' /usr/lib/libfprint-2.so.2.0.0
  ldconfig
  systemctl restart fprintd
"

echo
echo "==> Verifying"
LOADED="$(readlink -f /usr/lib/libfprint-2.so.2)"
echo "    /usr/lib/libfprint-2.so.2 -> $LOADED"
if command -v fprintd-list >/dev/null 2>&1; then
  fprintd-list "$USER" 2>&1 || true
fi

cat <<'EOF'

Done. Next steps:

  1. Enroll:  fprintd-enroll
     IMPORTANT: this sensor must be SWIPED (drag your finger across it),
     not tapped. A tap does not cover enough of your fingertip for reliable
     matching on this specific sensor -- see README.md for why.

  2. Verify:  fprintd-verify

  3. To use it for sudo/login/lock-screen, see the PAM section in
     README.md -- that part is NOT automated by this script since it edits
     system authentication files, and exact PAM file layout varies by distro
     / desktop environment (Omarchy users: see README.md's Omarchy section).

To revert to the original pacman libfprint at any time:
  sudo cp /root/libfprint-backup/libfprint-2.so.2.0.0.orig-pacman /usr/lib/libfprint-2.so.2.0.0
  sudo ldconfig && sudo systemctl restart fprintd
EOF
