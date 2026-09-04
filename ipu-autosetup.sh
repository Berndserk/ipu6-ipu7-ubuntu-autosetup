#!/usr/bin/env bash
# ipu6-ipu7-ubuntu-autosetup
# Automated IPU6/IPU7 MIPI camera enablement for Intel laptops (Dell Precision/Pro
# Max and similar Ubuntu-certified models) on any current Ubuntu release (LTS or
# interim).
# Run with: sudo bash ipu-autosetup.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root, e.g.: sudo bash $0" >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1 || ! command -v lsb_release >/dev/null 2>&1; then
  echo "This script only supports Debian/Ubuntu-based systems (needs apt-get + lsb_release)." >&2
  exit 1
fi


echo "== 1. Clean out any broken/old IPU6-7 stack (dev PPA + DKMS builds only) =="
# Only remove packages that came from Intel's known-fragile dev PPA
# (ppa:oem-solutions-group/intel-ipu6|7 - explicitly labelled "may often
# break your camera, use at your own risk") or the compiled-from-source
# DKMS driver. Packages already installed from a stable vendor OEM archive
# (dell/lenovo/hp.archive.canonical.com) are left untouched, so re-running
# this script does not churn/reinstall a working setup every time.
purge_if_ppa_sourced() {
  local pattern="$1"
  for pkg in $(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E "$pattern" || true); do
    origin=$(apt-cache policy "$pkg" 2>/dev/null | awk '$1=="***"{getline; print $2; exit}' || true)
    if [ -z "$origin" ] || echo "$origin" | grep -q 'ppa.launchpad.net'; then
      apt-get purge -y "$pkg" 2>/dev/null || true
    fi
  done
}

add-apt-repository --remove ppa:oem-solutions-group/intel-ipu6 -y 2>/dev/null || true
add-apt-repository --remove ppa:oem-solutions-group/intel-ipu7 -y 2>/dev/null || true
apt-get purge -y intel-ipu6-dkms intel-ipu7-dkms 2>/dev/null || true
purge_if_ppa_sourced 'oem-.*-meta'
purge_if_ppa_sourced 'libia-'
purge_if_ppa_sourced 'libgcss'
purge_if_ppa_sourced 'libipu'
purge_if_ppa_sourced 'libcamhal'
purge_if_ppa_sourced 'lib.*ipu6'
purge_if_ppa_sourced 'lib.*ipu7'
apt-get autoremove -y 2>/dev/null || true

echo "== 2. Install prebuilt (non-DKMS) IPU6/usbio kernel modules =="
apt-get update

REL=$(lsb_release -rs)
IS_LTS=$(grep -qi '"lts"\|LTS' /etc/os-release && echo yes || echo no)

install_first_that_exists() {
  # Tries each space-separated package-set (args) in turn, installs the first
  # one where every package actually exists in apt's cache. Never hard-fails.
  for pkgset in "$@"; do
    ok=yes
    for pkg in $pkgset; do
      apt-cache show "$pkg" >/dev/null 2>&1 || { ok=no; break; }
    done
    if [ "$ok" = yes ]; then
      # shellcheck disable=SC2086 # intentional word-splitting: $pkgset is a
      # space-separated list of package names, not a single argument.
      apt-get install --no-install-recommends --yes $pkgset
      return 0
    fi
  done
  return 1
}

if [ "$IS_LTS" = yes ]; then
  # LTS releases (24.04, 26.04, ...): HWE-suffixed packages carry the newer
  # enablement kernel + ipu6/usbio modules matched to it.
  install_first_that_exists \
    "linux-generic-hwe-${REL} linux-modules-ipu6-generic-hwe-${REL} linux-modules-usbio-generic-hwe-${REL}" \
    "linux-generic-hwe-24.04 linux-modules-ipu6-generic-hwe-24.04 linux-modules-usbio-generic-hwe-24.04" \
    || echo "!! No matching linux-modules-ipu6/usbio-*-hwe-${REL} package found yet. Check 'apt search linux-modules-ipu6' manually."
else
  # Interim (non-LTS) releases ship a recent mainline kernel already, so there
  # is no '-hwe-' suffix; the ipu6/usbio modules (if not already in-tree) use
  # the plain '-generic' naming instead.
  install_first_that_exists \
    "linux-modules-ipu6-generic linux-modules-usbio-generic" \
    || echo "!! No standalone linux-modules-ipu6/usbio-generic package found - the IPU6 driver is likely already built into this release's default kernel."
fi

echo "== 3. Add the correct vendor OEM archive =="
apt install -y ubuntu-oem-keyring
command -v ubuntu-drivers >/dev/null 2>&1 || apt-get install -y ubuntu-drivers-common
CODENAME=$(lsb_release -cs)
VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")

# Canonical publishes a separate OEM apt archive per laptop vendor, each under
# its own historical codename (unrelated to the Ubuntu release codename).
# These map 1:1 to a vendor, not a specific model - the model-specific piece
# is the oem-<branch>-*-meta package auto-detected in step 4 below.
case "$VENDOR" in
  *Dell*)
    OEM_HOST="dell.archive.canonical.com"; OEM_BRANCH="somerville" ;;
  *Lenovo*)
    OEM_HOST="lenovo.archive.canonical.com"; OEM_BRANCH="sutton" ;;
  *HP*|*"Hewlett"*)
    OEM_HOST="hp.archive.canonical.com"; OEM_BRANCH="stella" ;;
  *)
    echo "!! Unknown vendor '$VENDOR' - defaulting to Dell's archive. If this isn't a Dell,"
    echo "!! check https://wiki.ubuntu.com/OEMArchive for the correct host/branch and re-run"
    echo "!! with OEM_HOST/OEM_BRANCH env vars set, e.g.:"
    echo "!!   sudo OEM_HOST=lenovo.archive.canonical.com OEM_BRANCH=sutton bash ipu-autosetup.sh"
    OEM_HOST="dell.archive.canonical.com"; OEM_BRANCH="somerville" ;;
esac
OEM_HOST="${OEM_HOST_OVERRIDE:-$OEM_HOST}"
OEM_BRANCH="${OEM_BRANCH_OVERRIDE:-$OEM_BRANCH}"
[ -n "${OEM_HOST:-}" ] && [ -n "${OEM_BRANCH:-}" ] || { echo "OEM host/branch not set, aborting archive step"; exit 1; }

add-apt-repository -y "deb http://${OEM_HOST}/ ${CODENAME} ${OEM_BRANCH}"
apt update

echo "== 4. Detect and install correct OEM meta + HAL plugin =="
echo "---- ubuntu-drivers list output (copy this back if the script stops here) ----"
ubuntu-drivers list
echo "--------------------------------------------------------------------------"

# Try to auto-install anything matching oem-<branch>-*-meta and libcamhal*
META=$(ubuntu-drivers list 2>/dev/null | grep -m1 "oem-${OEM_BRANCH}.*-meta" || true)
HAL=$(ubuntu-drivers list 2>/dev/null | grep -m1 'libcamhal-ipu' || true)

if [ -n "$META" ]; then
  apt install -y "$META"
else
  echo "!! Could not auto-detect OEM meta package. Install manually from the list above."
fi

apt install -y libcamhal0 v4l2loopback-dkms v4l-utils gstreamer1.0-tools

if [ -n "$HAL" ]; then
  apt install -y "$HAL"
else
  echo "!! Could not auto-detect libcamhal-ipu6xxx plugin package."
  echo "!! Run 'ubuntu-drivers list' yourself and install the libcamhal-ipu6* entry manually."
fi

echo "== 5. Persist v4l2loopback module across reboots =="
# Without these two files, v4l2loopback would need a manual `modprobe` after
# every boot and might come up with the wrong /dev/videoN number or without
# exclusive_caps (which some apps like Chrome require to detect it as a
# real capture device rather than an output-only one).
cat >/etc/modules-load.d/v4l2loopback.conf <<'EOF'
v4l2loopback
EOF
cat >/etc/modprobe.d/v4l2loopback.conf <<'EOF'
options v4l2loopback devices=1 video_nr=0 card_label="Intel MIPI Camera" exclusive_caps=1
EOF

echo "== 6. Auto-probe the highest working resolution =="
echo "Reboot is required before this step works (kernel modules must be freshly loaded)."
echo "If you already rebooted after IPU6 modules were installed, probing now..."

# Stop any already-running relay first so it doesn't hold the sensor open
# and collide with the probe below (this happens on re-runs).
WAS_RUNNING=no
if systemctl is-active --quiet ipu6-camera.service 2>/dev/null; then
  WAS_RUNNING=yes
  systemctl stop ipu6-camera.service
fi

CANDIDATES="1920x1080 1600x1200 1280x800 1280x720 640x480"
BEST=""
PROBE_LOG=$(mktemp /tmp/ipu6-probe.XXXXXX.log)
trap 'rm -f "$PROBE_LOG"' EXIT

for RES in $CANDIDATES; do
  W=${RES%x*}; H=${RES#*x}
  echo "-- trying ${W}x${H} --"
  if timeout 6 gst-launch-1.0 -q icamerasrc num-buffers=5 ! \
       "video/x-raw,format=NV12,width=${W},height=${H},framerate=30/1" ! \
       fakesink >"$PROBE_LOG" 2>&1; then
    BEST="$RES"
    echo "-> ${W}x${H} works"
    break
  else
    echo "-> ${W}x${H} failed"
  fi
done

if [ -z "$BEST" ]; then
  echo "!! Auto-probe could not confirm any resolution (camera may need a reboot first)."
  echo "!! Defaulting the service to 1280x720 - re-run this script after rebooting to re-probe."
  BEST="1280x720"
fi
BEST_W=${BEST%x*}; BEST_H=${BEST#*x}
echo "== Using ${BEST_W}x${BEST_H} for the camera relay service =="

echo
echo "== Pass 2: systemd relay service =="
# icamerasrc (GStreamer) is the only supported way to pull frames out of the
# IPU6 HAL; there is no direct V4L2 capture API for it. This unit continuously
# re-encodes that stream as NV12 and pushes it into the v4l2loopback device
# from step 5, so ordinary V4L2/WebRTC apps can use it like a normal webcam.
# Restart=on-failure (not "always") + not enabled-at-boot: this service is
# meant to be started on demand via the cam-on alias below, not run 24/7.
tee /etc/systemd/system/ipu6-camera.service <<EOF
[Unit]
Description=Intel IPU6 Camera Relay (auto-probed ${BEST_W}x${BEST_H} -> v4l2loopback)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/gst-launch-1.0 -e icamerasrc buffer-count=7 ! \\
    video/x-raw,format=NV12,width=${BEST_W},height=${BEST_H},framerate=30/1 ! \\
    videoconvert ! v4l2sink device=/dev/video0
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
# Ubuntu's own v4l2-relayd@default.service targets the same use case but is
# known to crash-loop on several IPU6 platforms; disable it in favour of the
# unit above so the two don't fight over /dev/video0.
systemctl disable v4l2-relayd@default.service 2>/dev/null || true
systemctl stop v4l2-relayd@default.service 2>/dev/null || true

if [ "$WAS_RUNNING" = yes ]; then
  systemctl start ipu6-camera.service
  echo "Camera relay was running before this re-run; restarted it with the updated pipeline."
fi

echo "Service installed but NOT enabled/started-on-boot (camera LED would stay on)."
echo "Use these aliases to toggle it on demand:"

# Resolve the invoking (non-root) user's actual home/shell rather than
# root's, since the script itself always runs via sudo.
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6 || true)
LOGIN_SHELL=$(getent passwd "$REAL_USER" | cut -d: -f7 || true)

if [ -z "$REAL_HOME" ]; then
  echo "!! Could not resolve home directory for user '$REAL_USER' - skipping alias setup."
  echo "!! Add these manually to your shell rc file:"
  echo '  alias cam-on="sudo systemctl start ipu6-camera.service"'
  echo '  alias cam-off="sudo systemctl stop ipu6-camera.service"'
  echo '  alias cam-status="systemctl status ipu6-camera.service"'
else
  case "$LOGIN_SHELL" in
    */zsh) SHELL_RC="$REAL_HOME/.zshrc" ;;
    */bash|*) SHELL_RC="$REAL_HOME/.bashrc" ;;
  esac

  if ! grep -q "IPU6 Camera controls" "$SHELL_RC" 2>/dev/null; then
    {
      echo ''
      echo '# IPU6 Camera controls'
      echo 'alias cam-on="sudo systemctl start ipu6-camera.service"'
      echo 'alias cam-off="sudo systemctl stop ipu6-camera.service"'
      echo 'alias cam-status="systemctl status ipu6-camera.service"'
    } >> "$SHELL_RC"
    echo "Added aliases to $SHELL_RC (cam-on / cam-off / cam-status). Re-source your shell or re-login."
  else
    echo "Aliases already present in $SHELL_RC, skipping."
  fi
fi
