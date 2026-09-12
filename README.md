# ASUS X510UNR (ELAN7001) fingerprint reader on Linux

Getting the built-in fingerprint sensor working on an **ASUS X510UNR** (and
likely other ASUS/laptop models sharing the same **ELAN7001** ACPI ID) under
Linux. Windows ships a driver for this; mainline Linux ships none at all.

## Hardware

| | |
|---|---|
| Laptop | ASUS X510UNR |
| Sensor | ELAN7001, SPI-connected (`spi-ELAN7001:00`) |
| Sensor variant | ID 6 → `eFSA96SA`, 96x96 px |
| Touchpad HID (used for sensor reset) | `04F3:3057` |
| ACPI HID | `ELAN7001` |

If `find /sys/bus/acpi/devices -maxdepth 1 -iname "ELAN7001*"` (or
`ELAN70A1*`) finds something on your machine, this repo is relevant to you
even if your laptop model is different.

## The problem

1. Mainline Linux has **no kernel driver at all** for this ACPI ID — the
   sensor isn't exposed as any device node, not even a broken one.
2. `libfprint` (the userspace fingerprint library everything else builds on)
   *does* have a driver for this chip family (`elanspi`, merged upstream a
   few years ago), but nothing binds the kernel side, so it never gets a
   chance to run.
3. Even once wired up, this specific small square sensor (`eFSA96SA`,
   96x96px) yields far fewer minutiae per scan than the library's built-in
   match threshold expects (measured directly: ~4-10 out of a
   threshold of 24, on a *real, correct-finger* swipe — verified against a
   known-good reference image from libfprint's own test suite, which yields
   72+). The stock threshold essentially never clears on this hardware.

None of this is a "typo bug" you can casually patch away — it's three
separate, real gaps (no kernel binding, no persistent config, and a
threshold tuned for higher-yield sensor units than this one). This repo
closes all three.

## What this repo does

- A udev rule that binds the sensor's SPI device to the generic `spidev`
  driver (via the `driver_override` sysfs mechanism — no kernel recompile
  needed), persisted across reboots.
- A one-line patch to `libfprint`'s `elanspi` driver, lowering the
  hardcoded match threshold (`bz3_threshold`) from 24 to 5 so genuine
  same-finger swipes actually pass.
- An install script that builds and installs this patched `libfprint`
  alongside your distro's `fprintd` package.

## ⚠️ Security tradeoff — read this

Lowering the match threshold is a deliberate, informed tradeoff:
**lower threshold = higher false-accept risk.** In testing on one unit, a
handful of wrong-finger attempts were correctly rejected — but that is a
small sample, not a rigorous false-accept-rate measurement. Don't rely on
this for anything where a false accept is a real security concern (e.g. as
your *only* factor, or on a shared/untrusted-adjacent machine). Treat it as
"convenient, weaker than typical fingerprint auth," not "as secure as
Windows Hello."

If you'd rather keep the stock (much stricter, more often-fails) threshold,
skip the patch and just use the udev rule + a stock `libfprint` build.

## Install (Arch-based distros)

```sh
git clone https://github.com/arpitrohela/asus-x510unr-elan7001-fingerprint
cd asus-x510unr-elan7001-fingerprint
./install.sh
```

This installs build deps, sets up the udev rule, builds patched `libfprint`
from the upstream `v1.94.100` tag with the one-line patch applied, and
installs it over the pacman-managed copy (backing up the original first).

Then:

```sh
fprintd-enroll
```

**Important: you must genuinely swipe (drag your finger across the
sensor), not tap.** This sensor is architecturally a swipe-style capture
even though its physical package looks like a small square "tap" sensor —
a tap does not cover enough of your fingertip for the matcher to find
enough distinguishing ridge detail (this was extensively verified: tap
captures yield ~5 minutiae, real swipes yield ~4-10, and 24+ is what the
stock threshold wants). Expect the occasional `enroll-swipe-too-short` —
that's normal, it just means that particular swipe wasn't long/clean
enough, and it retries.

```sh
fprintd-verify
```

If it says `verify-match`, you're done at the `fprintd` level.

## Using it for sudo / login / lock screen (PAM)

This part isn't automated — it edits system authentication files, which
should be reviewed before applying, and the exact files differ by distro.
The safe pattern (used below) is `sufficient` — a failed/no fingerprint
always falls through to your normal password, so there's no lockout risk.

**Generic (any PAM-based distro), for `sudo`:**

```sh
sudo sed -i '1i auth       sufficient                  pam_fprintd.so' /etc/pam.d/sudo
```

**For a login manager / lock screen**, add the same line as the *first*
line of that service's PAM file (e.g. `/etc/pam.d/sddm`,
`/etc/pam.d/gdm-password`, `/etc/pam.d/system-login`) — check your distro's
docs for the right file, since a login manager not built with fingerprint
support in mind may not display a prompt for it even if PAM itself would
accept the scan.

**On Omarchy specifically**: the Quickshell lock screen has its own
built-in fingerprint support (`Super+Ctrl+L`), gated on a *separate* PAM
service, `/etc/pam.d/omarchy-lock-fingerprint`, plus `/etc/pam.d/polkit-1`
for polkit prompts. Omarchy's own `omarchy-setup-security-fingerprint`
script sets these up correctly (and adds a "skip fingerprint when the lid
is closed" gate) — but it bails out early on this hardware because its
hardware-detection helper (`omarchy-hw-fingerprint`) only checks USB
devices, and this sensor is SPI. Once this repo's udev rule + patched
`libfprint` are installed and `fprintd-enroll`/`fprintd-verify` both work,
you can safely run the PAM-setup portion of that script yourself instead of
duplicating it here — see `/usr/share/omarchy/bin/omarchy-setup-security-fingerprint`
for the exact commands (skip the `pacman -S libfprint-git ...` line, since
that would overwrite this patched build).

## Uninstalling / reverting

```sh
sudo cp /root/libfprint-backup/libfprint-2.so.2.0.0.orig-pacman /usr/lib/libfprint-2.so.2.0.0
sudo ldconfig
sudo systemctl restart fprintd
```

Then remove `/etc/udev/rules.d/99-elan-spi.rules` and
`/etc/modules-load.d/spidev.conf` if you want the sensor to go back to being
completely inert, and revert any PAM file edits you made.

## Credits

- [`mincrmatt12/elan-spi-fingerprint`](https://github.com/mincrmatt12/elan-spi-fingerprint) —
  the original reverse-engineering work for this sensor family, including
  the udev rule this repo reuses.
- [`libfprint`](https://gitlab.freedesktop.org/libfprint/libfprint) — the
  `elanspi` driver this repo patches one line of.

## License

The patch in `patches/` is against `libfprint`, licensed LGPL-2.1-or-later;
the patch itself is released under the same terms. Everything else in this
repo (install script, udev rule, this README) is MIT.
