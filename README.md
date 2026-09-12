# ASUS X510UNR (ELAN7001) fingerprint reader on Linux

The ASUS X510UNR has a fingerprint reader that works fine on Windows and does
absolutely nothing on Linux. Mainline Linux ships no driver for it at all, not
even a broken one. This repo is what it took to get it working, along with the
patch and instructions so you don't have to redo the digging.

## Hardware

| | |
|---|---|
| Laptop | ASUS X510UNR |
| Sensor | ELAN7001, SPI connected (`spi-ELAN7001:00`) |
| Sensor variant | ID 6, `eFSA96SA`, 96x96 px |
| Touchpad HID (used for sensor reset) | `04F3:3057` |
| ACPI HID | `ELAN7001` |

If `find /sys/bus/acpi/devices -maxdepth 1 -iname "ELAN7001*"` (or
`ELAN70A1*`) turns up something on your machine, this applies to you too even
if your laptop isn't an X510UNR. Same chip shows up on a bunch of other ASUS
models.

## What's actually wrong

Three separate things, not one:

1. The kernel has no driver for this ACPI ID whatsoever. The sensor doesn't
   show up as any device node until something binds it.
2. `libfprint` already has a driver for this sensor family (`elanspi`, merged
   upstream a while back), it's just never given the chance to run because
   nothing on the kernel side hands it a device.
3. Even once it's wired up, this particular sensor (the small square
   `eFSA96SA` variant) hands the matcher way fewer minutiae per scan than it
   wants. I measured it directly: a real, correct-finger swipe gets you
   something like 4 to 10 out of a required 24. For comparison, a known-good
   reference scan from libfprint's own test suite scores 72+. The stock
   threshold basically never clears on this hardware, swipe as carefully as
   you like.

None of that is a one-line bug. This repo fixes all three.

## What's in here

- A udev rule that binds the sensor's SPI device to the generic `spidev`
  driver using the `driver_override` sysfs trick, no kernel rebuild required,
  and persists across reboots.
- A one-line patch to `libfprint`'s `elanspi` driver that lowers the match
  threshold (`bz3_threshold`) from 24 to 5, low enough that genuine swipes
  actually pass.
- An install script that builds the patched `libfprint` and drops it in next
  to your distro's `fprintd` package.

## Read this before you install it

Lowering the match threshold is a real tradeoff, not a free lunch. A lower
threshold means a higher chance some other finger (or a similar print) also
scores above it. I tested a handful of wrong-finger attempts and they were
all correctly rejected, but that's a small sample size, not a real
false-accept-rate measurement. Don't use this as your only line of defense on
anything that actually matters. It's "convenient but weaker than normal
fingerprint auth," not "as secure as what Windows Hello does."

If you'd rather keep the stock threshold and just accept that most scans get
rejected, skip the patch and only use the udev rule with a normal
`libfprint` build.

## Installing it (Arch based distros)

```sh
git clone https://github.com/arpitrohela/asus-x510unr-elan7001-fingerprint
cd asus-x510unr-elan7001-fingerprint
./install.sh
```

This installs the build dependencies, sets up the udev rule, builds patched
`libfprint` from the `v1.94.100` tag with the one-line patch applied, and
installs it over the pacman-managed copy (the original gets backed up
first, nothing is thrown away).

Then enroll:

```sh
fprintd-enroll
```

One important thing: you have to actually swipe, drag your finger across the
sensor, not tap it. It looks like a little square tap sensor but the driver
underneath is architecturally a swipe reader, and a tap just doesn't cover
enough of your fingertip for it to find anything useful. I tested this too:
taps land around 5 minutiae, real swipes land around 4 to 10, and the
matcher wants 24+. You'll probably see `enroll-swipe-too-short` a few times
during enrollment. That's normal, it just means that particular swipe wasn't
clean or long enough, and it'll ask you to try again.

Then verify:

```sh
fprintd-verify
```

If you get `verify-match`, it works.

## Wiring it into sudo, login, or the lock screen (PAM)

I didn't automate this part on purpose. It edits your system's
authentication files, and the exact files differ by distro, so it deserves a
look before you run it rather than a script silently rewriting your auth
stack. The pattern below is the safe one: `sufficient` means a failed or
missing fingerprint just falls through to your normal password, no lockout
risk.

**For sudo, on basically any PAM-based distro:**

```sh
sudo sed -i '1i auth       sufficient                  pam_fprintd.so' /etc/pam.d/sudo
```

**For polkit (this is what makes `pkexec` and most graphical "authenticate"
prompts work)**, create `/etc/pam.d/polkit-1` if it doesn't already exist:

```sh
sudo tee /etc/pam.d/polkit-1 >/dev/null <<'EOF'
auth      sufficient pam_fprintd.so
auth      required pam_unix.so

account   required pam_unix.so
password  required pam_unix.so
session   required pam_unix.so
EOF
```

I confirmed this myself: once that file is in place, `pkexec true` prompts
for a fingerprint instead of going straight to a password. On Omarchy there's
an extra line worth adding that skips the fingerprint check entirely when
your laptop lid is closed (so it doesn't sit there waiting on a sensor it
can't reach), see the Omarchy section below for that version.

**For a login manager or lock screen**, add the same line as the first line
of that service's PAM file, something like `/etc/pam.d/sddm`,
`/etc/pam.d/gdm-password`, or `/etc/pam.d/system-login` depending on what you
run. Check your distro's docs for the right file. Also worth knowing: some
login managers were never built to expect a fingerprint prompt, so even if
PAM would accept the scan, the UI might not show anything for it.

**If you're on Omarchy specifically**, the Quickshell lock screen already has
fingerprint support built in (`Super+Ctrl+L`), it's just gated behind a
separate PAM service at `/etc/pam.d/omarchy-lock-fingerprint`, plus
`/etc/pam.d/polkit-1` for polkit prompts. Omarchy ships its own
`omarchy-setup-security-fingerprint` script that sets all of this up
correctly, including a "skip fingerprint when the lid is closed" gate. It
just never runs on this hardware because its detection helper
(`omarchy-hw-fingerprint`) only checks USB devices, and this sensor is SPI.
Once this repo's udev rule and patched `libfprint` are in and
`fprintd-enroll`/`fprintd-verify` both work, it's safe to run the PAM part of
that script by hand. Open
`/usr/share/omarchy/bin/omarchy-setup-security-fingerprint` and copy the
commands, just skip the `pacman -S libfprint-git ...` line since that would
overwrite the patched build you just installed.

## Undoing all of this

```sh
sudo cp /root/libfprint-backup/libfprint-2.so.2.0.0.orig-pacman /usr/lib/libfprint-2.so.2.0.0
sudo ldconfig
sudo systemctl restart fprintd
```

Then delete `/etc/udev/rules.d/99-elan-spi.rules` and
`/etc/modules-load.d/spidev.conf` if you want the sensor fully inert again,
and undo whatever PAM edits you made.

## Credits

- [`mincrmatt12/elan-spi-fingerprint`](https://github.com/mincrmatt12/elan-spi-fingerprint)
  did the original reverse engineering on this sensor family, the udev rule
  here is theirs.
- [`libfprint`](https://gitlab.freedesktop.org/libfprint/libfprint) is where
  the `elanspi` driver actually lives, this repo just patches one line of it.

## License

The patch in `patches/` touches `libfprint`, which is LGPL-2.1-or-later, so
the patch is released under the same terms. Everything else here (install
script, udev rule, this README) is MIT.
