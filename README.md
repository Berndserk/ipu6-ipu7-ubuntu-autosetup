# ipu6-ipu7-ubuntu-autosetup

One script to get the built-in **Intel IPU6/IPU7 MIPI camera** working reliably on
Ubuntu-based laptops (Dell Precision/Pro Max, Lenovo, HP, ...) — using only
apt-managed, non-DKMS packages so it survives normal `apt upgrade` and kernel
updates.

## The problem

Modern Intel laptops (Tiger Lake through Arrow Lake/Meteor Lake) ditched plug-and-play
USB webcams (UVC) for MIPI/CSI cameras driven by Intel's **IPU6/IPU7** image
processing unit. Unlike UVC, there is no single "camera driver" — you need:

- a kernel driver for the IPU + the sensor + the IVSC (privacy/visual sensing controller)
- a proprietary-ish userspace HAL (`libcamhal`) that talks to the IPU firmware
- a GStreamer plugin (`icamerasrc`) to pull frames out of the HAL
- a `v4l2loopback` virtual device so normal apps (Chrome, Teams, Zoom, Slack) can
  see the camera as a standard `/dev/videoN` device

Intel's `intel-ipu6-dkms` package and Canonical's `oem-solutions-group` **development**
PPAs are the two routes most guides point you to — but both are explicitly called out
upstream as fragile (DKMS breaks on every kernel bump; the dev PPAs are "not for daily
use, may often break the camera").

This script instead uses the **stable, apt-packaged route**: prebuilt (non-DKMS) kernel
modules from Ubuntu's HWE stack + your laptop vendor's official Canonical OEM archive
(e.g. Dell's `somerville` branch), which is the same stack Ubuntu's own
[IntelMIPICamera wiki page](https://wiki.ubuntu.com/IntelMIPICamera) recommends for
daily use.

## What it does

1. **Cleans up** any packages that came from the fragile dev PPAs or `intel-ipu6-dkms`
   (only if they're actually from that PPA — packages already installed from your
   vendor's stable OEM archive are left alone, so re-running this script doesn't
   churn a working setup).
2. Installs the prebuilt **IPU6/usbio kernel modules** matched to your Ubuntu release
   (HWE-suffixed on LTS, plain `-generic` on interim releases).
3. Detects your laptop vendor from DMI and adds the matching **Canonical OEM archive**
   (Dell → `somerville`, Lenovo → `sutton`, HP → `stella`; override via env vars for
   anything else).
4. Auto-detects and installs the correct **`libcamhal-ipu6/7*` HAL plugin** for your
   specific sensor/platform via `ubuntu-drivers list`.
5. Sets up **`v4l2loopback`** to persist across reboots.
6. **Auto-probes** the sensor for its actual highest working resolution (tries
   1920x1080 down to 640x480 against the real hardware) instead of guessing/hardcoding
   one.
7. Installs a **systemd service** (`ipu6-camera.service`) that relays
   `icamerasrc → v4l2loopback` at the probed resolution — this replaces Ubuntu's
   built-in `v4l2-relayd`, which is known to crash-loop on several platforms.
8. Adds `cam-on` / `cam-off` / `cam-status` shell aliases so you control the camera
   manually — the relay is **not** enabled to autostart at boot, since running it
   means the camera LED stays on and the sensor is actively streaming the whole time.

The script is **idempotent**: safe to re-run any time (e.g. after a `sudo reboot`, so
the resolution probe can run against freshly-loaded kernel modules, or on a fresh
install of the same hardware).

## Requirements

- A Debian/Ubuntu-based system with `apt-get` + `lsb_release` (tested on Ubuntu 24.04
  and 26.04)
- **bash** to run the script itself (it uses `set -o pipefail`, which is not
  POSIX/`sh`-compatible — always invoke it as `sudo bash ipu-autosetup.sh`, never
  `sh ipu-autosetup.sh`). Your own login shell doesn't matter — bash, zsh, and fish are
  all fine, since the script explicitly runs under bash regardless.
- An Intel IPU6/IPU7 MIPI camera (check with `cat /sys/class/video4linux/*/name` — you
  should see something like `Intel IPU6 CSI2 0` and a sensor name such as `ov02e10`,
  `ov01a10`, `hi556`, etc.)

## Usage

```bash
sudo bash ipu-autosetup.sh
sudo reboot
sudo bash ipu-autosetup.sh   # re-run once, so the kernel modules are loaded before
                          # the resolution probe (step 6) runs
```

Then, day to day:

```bash
cam-on       # starts the relay (asks for sudo password); camera LED turns on
cam-off      # stops it; LED off
cam-status   # check whether it's currently running
```

`(you may need to `source ~/.bashrc` or open a new terminal once for the aliases to
become available)`

### Browser support

- **Firefox / Chrome / Edge**: work out of the box once the relay is running.
- Chrome/Edge may need `chrome://flags/#enable-webrtc-pipewire-camera` enabled once on
  some setups if the camera doesn't show up in a site's device picker.

### Known incompatible apps

GNOME's built-in **Camera app** and **Cheese**, as well as **guvcview**, have known
issues previewing `v4l2loopback`-bridged IPU6 devices (format negotiation / portal
bugs — see [Ubuntu bug 1978757](https://bugs.launchpad.net/bugs/1978757)). This does
**not** affect Chrome, Firefox, Edge, Zoom, Teams, or Slack, which all use the standard
WebRTC/V4L2 path and work fine. If you want a quick local preview anyway:

```bash
ffplay -f v4l2 -pixel_format nv12 -video_size 1920x1080 /dev/video0
```
(adjust the resolution to whatever `ipu6-camera.service`'s unit file shows).

## Troubleshooting

```bash
cat /sys/class/video4linux/*/name          # confirm the sensor is detected
sudo dmesg | grep -iE 'ipu6|ipu7|ivsc'     # kernel-side driver/firmware status
v4l2-ctl --list-devices                    # confirm /dev/video0 (loopback) exists
ls -la /usr/lib/libcamhal/plugins/         # confirm the correct *.so HAL plugin exists
systemctl status ipu6-camera.service       # check the relay service
journalctl -u ipu6-camera.service -b       # relay service logs
```

If `ubuntu-drivers list` doesn't show an `oem-<vendor-branch>-*-meta` package for your
exact model yet, that's fine — it's just a convenience/branding wrapper. As long as
`libcamhal-ipu6*`/`libcamhal-ipu7*` installed correctly in step 4, the camera stack
itself is complete.

## Supported hardware

Confirmed working:

| Laptop                  | Sensor    | Resolution |
|--------------------------|-----------|------------|
| Dell Precision 5690      | ov02e10   | 1920x1080  |

Should also work (untested, same mechanism) on any Ubuntu-certified Dell/Lenovo/HP
laptop with an IPU6 or IPU7 MIPI camera — PRs adding your hardware to this table are
welcome!

## Why not Fedora?

Fedora's IPU6/IPU7 support uses a fully open-source `libcamera` software-ISP pipeline
(no proprietary HAL blobs) and is generally the better long-term architecture — but as
of this writing it's enabled per sensor/platform and may lag behind newer CPU
generations. If you're not tied to Ubuntu for other reasons (e.g. MDM/Intune
enrollment), it's worth checking whether your hardware is already supported there.

## License

MIT — see [LICENSE](LICENSE).
