#!/usr/bin/env bash
# Run on the new Mint install, from the copied 3-linux folder:
#   sudo bash 1-system-setup.sh
# Installs English + a second language (English default), Chrome, LibreOffice, PDF reader, printer drivers, fonts,
# and the fixes old Macs need (each one only runs when its hardware is present).
# Time zone is left as chosen in the installer. English only by default; for a second language the user can switch
# to in Settings > Languages, pass it: sudo LANG2=es_CO bash 1-system-setup.sh   (or fr_FR, de_DE, pt_BR, ...)
# IOMMU_OFF=1 adds intel_iommu=off, for the Marvell SSDs in some 2013-14 Macs that otherwise fail to boot.
# TB=1 keeps Thunderbolt powered on MacBook Airs (by default it's off unless connected at start-up).
set -uo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }
log() { printf '\n==> %s\n' "$*"; }
has_pci() { lspci -nn | grep -qi "$1"; }
APPLE=$(grep -qi apple /sys/class/dmi/id/sys_vendor 2>/dev/null && echo 1 || echo 0)
LANG2="${LANG2:-}"; L2="${LANG2%%_*}"
# Wait for Mint's automatic updates instead of failing when they hold the package lock
echo 'DPkg::Lock::Timeout "600";' > /etc/apt/apt.conf.d/90mintosh-lock-wait

if [ -n "${IOMMU_OFF:-}" ]; then
  log "SSD: Intel IOMMU off (some Marvell 88SS9183 SSDs in 2013-14 MacBook Air/Pro fail to IDENTIFY with it on)"
  grep -q intel_iommu=off /etc/default/grub || sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&intel_iommu=off /' /etc/default/grub
elif has_pci '1b4b:9183'; then
  echo "   Marvell 88SS9183 SSD: if it fails to boot with 'failed to IDENTIFY' errors (seen on Toshiba TS0256F), re-run with IOMMU_OFF=1"
fi
# Thunderbolt off when nothing is plugged in at start-up (MacBook Airs; ~0.7 W at idle on a 2013 Air). Linux tells
# Apple's firmware it is macOS (_OSI "Darwin"), and the firmware then keeps the Thunderbolt controller powered all
# the time; without it, the firmware switches it off at start-up. Thunderbolt devices then only work when connected
# before start-up. TB=1 keeps Thunderbolt on.
if grep -q '^MacBookAir' /sys/class/dmi/id/product_name 2>/dev/null && lspci | grep -qi thunderbolt && [ "${TB:-}" != 1 ]; then
  log "Thunderbolt: off unless connected at start-up (saves ~0.7 W; TB=1 keeps it on)"
  grep -q 'acpi_osi=!Darwin' /etc/default/grub || sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&acpi_osi=!Darwin /' /etc/default/grub
elif [ "${TB:-}" = 1 ]; then
  sed -i 's/acpi_osi=!Darwin //' /etc/default/grub
fi
# SATA link power saving depends on who made the SSD: Toshiba (APPLE SSD TS...) drops the link with it on (freezes
# after ~1 h), SanDisk (APPLE SSD SD...) drops it with it OFF (errors within a minute, link slows to 1.5 Gb/s).
# LPM_OFF=1 / LPM_OFF=0 overrides the guess.
# The disk the system is on (not just "sda": a USB stick or a second disk can take that name)
SSD=$(cat "/sys/block/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -1)/device/model" 2>/dev/null | xargs)
if [ "${LPM_OFF:-}" = 1 ] || { [ -z "${LPM_OFF:-}" ] && [[ "$SSD" == "APPLE SSD TS"* ]]; }; then
  log "SSD ($SSD): drops the SATA link (freezes, I/O errors) with link power saving on - keep it off"
  grep -q mobile_lpm_policy /etc/default/grub || sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&ahci.mobile_lpm_policy=1 /' /etc/default/grub
elif [ "${LPM_OFF:-}" = 0 ]; then
  sed -i 's/ahci.mobile_lpm_policy=1 //' /etc/default/grub
fi

# Sleep like a Mac: a Mac in sleep writes memory to disk after 3 h ("standby") and powers off, so it lasts weeks
# instead of days and a flat battery loses nothing. Here: every sleep (lid, menu, idle, low battery) is
# suspend-then-hibernate. Hibernation needs a swapfile at least as big as RAM on an ext4 root, and no Secure Boot
# lockdown. Laptops only.
if ls /sys/class/power_supply/BAT* >/dev/null 2>&1 && grep -qw disk /sys/power/state \
   && [ "$(findmnt -no FSTYPE /)" = ext4 ] && ! grep -q '\[\(integrity\|confidentiality\)\]' /sys/kernel/security/lockdown 2>/dev/null; then
  log "Sleep like a Mac: after 3 h asleep, save to disk and power off (resumes where it left off)"
  ram=$(awk '/MemTotal/{print int($2/1048576)+1}' /proc/meminfo)   # GiB, rounded up
  have=$(stat -c %s /swapfile 2>/dev/null || echo 0)
  if [ "$have" -lt $((ram << 30)) ]; then
    # Room for the new one (plus 2 GiB to spare) before the old one goes
    if [ $(( $(df --output=avail -B1 / | tail -1) + have )) -gt $(( (ram + 2) << 30 )) ]; then
      # A swapfile still in use (swapoff can fail when memory is short) stays; this run then skips hibernation
      if [ "$have" = 0 ] || swapoff /swapfile 2>/dev/null; then
        rm -f /swapfile
        fallocate -l "${ram}G" /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null || rm -f /swapfile
      fi
    fi
  fi
  [ -f /swapfile ] && { grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab; }
  swapon /swapfile 2>/dev/null
  OFFSET=$(filefrag -v /swapfile 2>/dev/null | awk '$1=="0:"{print $4+0}')
fi
if [ -n "${OFFSET:-}" ] && [ "$(stat -c %s /swapfile)" -ge $((ram << 30)) ]; then
  RESUME="resume=UUID=$(findmnt -no UUID /) resume_offset=$OFFSET"
  sed -i -E 's/ ?resume(_offset)?=[^ "]*//g; s/^GRUB_CMDLINE_LINUX_DEFAULT=" */GRUB_CMDLINE_LINUX_DEFAULT="'"$RESUME"' /' /etc/default/grub
  echo "RESUME=${RESUME#resume=}" > /etc/initramfs-tools/conf.d/resume
  update-initramfs -u
  mkdir -p /etc/systemd/sleep.conf.d /etc/systemd/system/systemd-suspend.service.d /etc/polkit-1/rules.d
  printf '[Sleep]\nHibernateDelaySec=3h\n' > /etc/systemd/sleep.conf.d/90-mintosh.conf
  # Whatever asks for sleep gets suspend-then-hibernate
  printf '[Service]\nExecStart=\nExecStart=/usr/lib/systemd/systemd-sleep suspend-then-hibernate\n' \
    > /etc/systemd/system/systemd-suspend.service.d/90-mintosh.conf
  systemctl daemon-reload
  # Ubuntu's polkit rules hide hibernation from the desktop; the power manager needs it for the low-battery action
  rm -f /etc/polkit-1/rules.d/50-mintosh-hibernate.rules   # older name; rules run in name order, before Ubuntu's
  cat > /etc/polkit-1/rules.d/10-mintosh-hibernate.rules <<'EOF'
polkit.addRule(function(action, subject) {
  if (/^org\.freedesktop\.login1\.hibernate/.test(action.id) && subject.local && subject.active)
    return polkit.Result.YES;
});
EOF
else
  # No usable hibernation (no room, Secure Boot turned on later, ...): sleep must stay plain sleep
  [ -n "${ram:-}" ] && echo "!! No room for a ${ram} GB swapfile on / - sleep stays plain sleep (no save to disk after 3 h)"
  if [ -f /etc/systemd/system/systemd-suspend.service.d/90-mintosh.conf ]; then
    rm -f /etc/systemd/system/systemd-suspend.service.d/90-mintosh.conf /etc/systemd/sleep.conf.d/90-mintosh.conf \
      /etc/polkit-1/rules.d/*-mintosh-hibernate.rules /etc/initramfs-tools/conf.d/resume
    sed -i -E 's/ ?resume(_offset)?=[^ "]*//g; s/^GRUB_CMDLINE_LINUX_DEFAULT=" */GRUB_CMDLINE_LINUX_DEFAULT="/' /etc/default/grub
    systemctl daemon-reload; update-initramfs -u
  fi
fi
update-grub

# Broadcom's wl driver only for the chips it supports: its package turns off the open brcmfmac driver, which is the
# one the 2015 MacBook Pro (BCM43602) and the 12" MacBook (BCM4350) need
WL_IDS="4311 4312 4313 4315 4328 4329 432a 432b 432c 432d 4331 4353 4357 4358 4359 4365 43a0 43b1 4727"
BRCM=$(lspci -nn -d 14e4: | grep -i 'network controller' | grep -oP '14e4:\K[0-9a-f]{4}' | head -1)
if [ -n "$BRCM" ] && [[ " $WL_IDS " == *" $BRCM "* ]]; then
  log "Wi-Fi driver (Broadcom $BRCM: wl) + power saving off (wl drops the connection with it on)"
  lsmod | grep -q '^wl ' || apt-get install -y bcmwl-kernel-source || echo "!! Wi-Fi driver failed - use Driver Manager"
  printf '[connection]\nwifi.powersave = 2\n' > /etc/NetworkManager/conf.d/99-wifi-powersave-off.conf
elif [ -n "$BRCM" ]; then
  echo "   Broadcom $BRCM Wi-Fi: uses the built-in brcmfmac driver (needs no install)"
fi

log "Update system"
apt-get update && apt-get -y full-upgrade

log "English${LANG2:+ (default) + $LANG2, switchable in Settings > Languages}"
apt-get install -y language-pack-en language-pack-gnome-en hunspell-en-us || true
[ -z "$LANG2" ] || apt-get install -y "language-pack-$L2" "language-pack-gnome-$L2" "hunspell-$L2" || true
locale-gen en_US.UTF-8 ${LANG2:+"$LANG2.UTF-8"}
update-locale LANG=en_US.UTF-8 LANGUAGE=en_US:en

log "Microsoft fonts so Word documents look the same"
echo 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true' | debconf-set-selections
apt-get install -y ttf-mscorefonts-installer fonts-crosextra-carlito fonts-crosextra-caladea fonts-inter   # Inter: open stand-in for Apple's SF Pro

log "Office (English${L2:+ + $L2}), Mac-look dock, tools"
apt-get install -y libreoffice libreoffice-help-en-us mythes-en-us \
  plank git sassc libglib2.0-dev-bin libxml2-utils xdotool xprintidle \
  convmv rsync openssh-server
[ -z "$L2" ] || apt-get install -y "libreoffice-l10n-$L2" "libreoffice-help-$L2" "hyphen-$L2" "mythes-$L2" || true

log "iPhone photos (HEIC) open and show thumbnails like JPGs"
apt-get install -y heif-gdk-pixbuf heif-thumbnailer || true

log "Chrome"
DEB=google-chrome-stable_current_amd64.deb
[ -f "$DEB" ] || wget -q -O "/tmp/$DEB" "https://dl.google.com/linux/direct/$DEB"
apt-get install -y "./$DEB" 2>/dev/null || apt-get install -y "/tmp/$DEB"

log "Chrome: h264ify, so YouTube sends H.264 (decoded by the graphics chip on 2012-15 Macs; VP9/AV1 drain the battery)"
mkdir -p /etc/opt/chrome/policies/managed
cat > /etc/opt/chrome/policies/managed/mintosh.json <<'EOF'
{ "ExtensionInstallForcelist": ["aleakchihdccplidncghkekgioiakgal;https://clients2.google.com/service/update2/crx"] }
EOF

log "Memory like macOS: compress it before swapping (zswap), and close the biggest app rather than freeze (earlyoom)"
# macOS compresses memory, so a 4 GB Mac copes with many tabs; Linux otherwise writes to swap early and stutters
printf 'w /sys/module/zswap/parameters/enabled - - - - Y\nw /sys/module/zswap/parameters/compressor - - - - zstd\n' \
  > /etc/tmpfiles.d/90-mintosh-zswap.conf
systemd-tmpfiles --create /etc/tmpfiles.d/90-mintosh-zswap.conf || true
apt-get install -y earlyoom && systemctl enable --now earlyoom

log "Make LibreOffice save in Word/Excel formats by default"
P=/usr/lib/libreoffice/share/registry   # every .xcd here is loaded at startup
cat > "$P/msformats.xcd" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<oor:data xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:oor="http://openoffice.org/2001/registry">
<dependency file="main"/>
<oor:component-data oor:name="Setup" oor:package="org.openoffice">
 <node oor:name="Office"><node oor:name="Factories">
  <node oor:name="com.sun.star.text.TextDocument"><prop oor:name="ooSetupFactoryDefaultFilter"><value>MS Word 2007 XML</value></prop></node>
  <node oor:name="com.sun.star.sheet.SpreadsheetDocument"><prop oor:name="ooSetupFactoryDefaultFilter"><value>Calc MS Excel 2007 XML</value></prop></node>
  <node oor:name="com.sun.star.presentation.PresentationDocument"><prop oor:name="ooSetupFactoryDefaultFilter"><value>Impress MS PowerPoint 2007 XML</value></prop></node>
 </node></node>
</oor:component-data>
</oor:data>
EOF
log "Make Chrome the default browser"
update-alternatives --set x-www-browser /usr/bin/google-chrome-stable || true

log "Printers: common Epson (escpr) and Canon/other (gutenprint) drivers"
apt-get install -y printer-driver-escpr printer-driver-gutenprint
echo "   Newer Canon inkjets (e.g. G2010): if not auto-detected, use Canon's 'cnijfilter2' driver"

# Laptops only: on an iMac or Mac mini it can't see the graphics chip's or hard drive's heat
if [ "$APPLE" = 1 ] && [[ " 8 9 10 14 " == *" $(cat /sys/class/dmi/id/chassis_type 2>/dev/null) "* ]]; then
  log "Mac fan control (mbpfan)"
  apt-get install -y mbpfan && systemctl enable --now mbpfan
fi
if has_pci '14e4:1570'; then
  log "FaceTime HD camera (third-party facetimehd driver, rebuilt by DKMS on kernel updates)"
  # Headers for every future kernel too (the meta package that matches the installed kernel series)
  HDR=$(dpkg-query -W -f='${Package}\n' 'linux-generic*' 2>/dev/null | grep -v headers | head -1 | sed 's/^linux-generic/linux-headers-generic/')
  apt-get install -y dkms build-essential "linux-headers-$(uname -r)" ${HDR:+"$HDR"} curl xz-utils cpio
  F=$(mktemp -d)
  git clone -q --depth 1 https://github.com/patjak/facetimehd-firmware.git "$F/firmware"
  git clone -q --depth 1 https://github.com/patjak/facetimehd.git "$F/driver"
  echo 'blacklist bdc_pci' > /etc/modprobe.d/facetimehd.conf   # claims the same PCI ID
  (cd "$F/firmware" && make && make install) || echo "!! camera firmware failed"
  V=$(grep -oP '^PACKAGE_VERSION="?\K[^"]+' "$F/driver/dkms.conf")
  rm -rf "/usr/src/facetimehd-$V" && cp -r "$F/driver" "/usr/src/facetimehd-$V"
  # On a re-run it's already added/installed (captured, not piped to grep -q: SIGPIPE fails it under pipefail)
  { [ -n "$(dkms status -m facetimehd -v "$V" 2>/dev/null)" ] || dkms add -m facetimehd -v "$V"; } &&
    { [[ "$(dkms status -m facetimehd -v "$V" -k "$(uname -r)" 2>/dev/null)" == *installed* ]] || dkms install -m facetimehd -v "$V"; } &&
    modprobe facetimehd || echo "!! camera driver failed (check kernel support)"
  # A camera driver that won't build for a new kernel must never stop updates: DKMS's own automatic build fails the
  # kernel's install and leaves apt broken (no more security updates). Build it from a hook that always succeeds.
  sed -i 's/^AUTOINSTALL=.*/AUTOINSTALL=""/' "/usr/src/facetimehd-$V/dkms.conf"
  cat > /etc/kernel/postinst.d/zz-mintosh-facetimehd <<EOF
#!/bin/sh
# mintosh: build the FaceTime HD camera driver for a new kernel; a failure is logged, never fatal
dkms install -m facetimehd -v $V -k "\$1" >/dev/null 2>&1 || logger -t mintosh "facetimehd did not build for \$1"
exit 0
EOF
  chmod 755 /etc/kernel/postinst.d/zz-mintosh-facetimehd
  for k in /lib/modules/*/build; do k=${k%/build}; k=${k##*/}; /etc/kernel/postinst.d/zz-mintosh-facetimehd "$k"; done
  rm -rf "$F"
fi

if has_pci '14e4:1570'; then
  log "Camera link power saving, so the processor can reach its deep idle states (package 2.1 W -> ~1 W at idle on a 2013 Air)"
  # Apple's firmware leaves the camera's PCIe link without its common clock set and with power saving (ASPM) off,
  # and Linux keeps the firmware's link settings. A link that never idles keeps the whole processor package out of
  # PC6/PC7. Set the clock as the camera side already has it, retrain, then allow L1. At start-up and after sleep.
  cat > /usr/local/sbin/mintosh-camera-link <<'EOF'
#!/bin/sh
# mintosh: power saving (ASPM L1) on the FaceTime HD camera's PCIe link
D=$(lspci -D -d 14e4:1570 | awk 'NR==1{print $1}'); [ -n "$D" ] || exit 0
R=$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$D")")")
setpci -s "$R" CAP_EXP+0x10.w=0x0040:0x0040   # common clock
setpci -s "$R" CAP_EXP+0x10.w=0x0020:0x0020   # retrain the link with it
sleep 0.2
setpci -s "$D" CAP_EXP+0x10.w=0x0002:0x0003   # L1: camera side first, then the port
setpci -s "$R" CAP_EXP+0x10.w=0x0002:0x0003
EOF
  chmod 755 /usr/local/sbin/mintosh-camera-link
  printf '[Unit]\nDescription=mintosh: camera link power saving\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/mintosh-camera-link\n[Install]\nWantedBy=multi-user.target\n' \
    > /etc/systemd/system/mintosh-camera-link.service
  systemctl daemon-reload; systemctl enable --now mintosh-camera-link
fi

log "Login screen: macOS Sonoma-style wallpaper (WhiteSur recreation)"
W=$(mktemp -d)
git clone -q --depth 1 https://github.com/vinceliuice/WhiteSur-wallpapers.git "$W" &&
  install -D -m 644 "$W/4k/Sonoma-light.jpg" /usr/share/backgrounds/macos/Sonoma-light.jpg
rm -rf "$W"
[ -f /etc/lightdm/slick-greeter.conf ] || printf '[Greeter]\n' > /etc/lightdm/slick-greeter.conf
sed -i '/^background=/d;/^draw-user-backgrounds=/d' /etc/lightdm/slick-greeter.conf
sed -i '/^\[Greeter\]/a background=/usr/share/backgrounds/macos/Sonoma-light.jpg\ndraw-user-backgrounds=false' /etc/lightdm/slick-greeter.conf

log "Log in with a password (no autologin), so the keyring unlocks itself and never prompts"
sed -i -E 's/^(\s*autologin-user)/#\1/' /etc/lightdm/lightdm.conf 2>/dev/null || true

log "Automatic updates (security + kernel) via Mint Update Manager"
mintupdate-automation upgrade enable || true
mintupdate-automation autoremove enable || true

log "Sleep and wake for the Mac drivers that don't handle it themselves (camera, Broadcom Wi-Fi)"
cat > /usr/lib/systemd/system-sleep/mintosh <<'EOF'
#!/bin/sh
# mintosh: the FaceTime camera driver has no sleep support: unload it before sleep (unless a call is using it) and
# load it after. Broadcom's wl driver often comes back from a resume from disk without Wi-Fi: reload it then.
case "$1" in
  pre) lsmod | grep -q '^facetimehd ' && modprobe -r facetimehd 2>/dev/null && touch /run/mintosh-camera ;;
  post)
    # suspend-then-hibernate says which one actually happened in SYSTEMD_SLEEP_ACTION
    if [ "${SYSTEMD_SLEEP_ACTION:-$2}" = hibernate ] && lsmod | grep -q '^wl '; then modprobe -r wl && modprobe wl; fi
    [ -f /run/mintosh-camera ] && { modprobe facetimehd; rm -f /run/mintosh-camera; }
    [ -x /usr/local/sbin/mintosh-camera-link ] && /usr/local/sbin/mintosh-camera-link
    ;;
esac
exit 0
EOF
chmod 755 /usr/lib/systemd/system-sleep/mintosh

if dpkg -s bcmwl-kernel-source >/dev/null 2>&1; then
  log "If a kernel update leaves the Wi-Fi driver behind, start the previous kernel (no Wi-Fi = no update to fix it)"
  # The boot menu is hidden, so nobody would pick the old kernel by hand. Checked at each start, before the login
  # screen; once the newest kernel has its Wi-Fi driver again, starting it is the default again.
  printf 'GRUB_DEFAULT=saved\n' > /etc/default/grub.d/90-mintosh-default.cfg
  cat > /usr/local/sbin/mintosh-bootcheck <<'EOF'
#!/bin/bash
# mintosh: start the newest kernel that has the Broadcom Wi-Fi driver (wl)
running=$(uname -r); newest=$(ls /lib/modules | sort -V | tail -1); cfg=/boot/grub/grub.cfg
has_wl() { [ -n "$(find "/lib/modules/$1" -name 'wl.ko*' 2>/dev/null | head -1)" ]; }
entry() {
  local sub id
  sub=$(grep -oP "^submenu .*menuentry_id_option '\Kgnulinux-advanced-[^']+" "$cfg" | head -1)
  id=$(grep -oP "menuentry_id_option '\Kgnulinux-$1-advanced-[^']+" "$cfg" | head -1)
  [ -n "$sub" ] && [ -n "$id" ] && echo "$sub>$id"
}
if has_wl "$running"; then
  if [ "$running" != "$newest" ] && has_wl "$newest"; then grub-set-default 0; fi   # fixed by a later update
  exit 0
fi
mkdir -p /var/lib/mintosh; tried=/var/lib/mintosh/bootcheck-tried-$running
[ -f "$tried" ] && exit 0   # tried once already for this kernel: never loop
for k in $(ls /lib/modules | sort -rV); do
  [ "$k" != "$running" ] && [ -f "/boot/vmlinuz-$k" ] && has_wl "$k" || continue
  e=$(entry "$k") || continue
  touch "$tried"; logger -t mintosh "no Wi-Fi driver for $running; starting $k instead"
  grub-set-default "$e" && systemctl reboot
  exit 0
done
EOF
  chmod 755 /usr/local/sbin/mintosh-bootcheck
  cat > /etc/systemd/system/mintosh-bootcheck.service <<'EOF'
[Unit]
Description=mintosh: start the previous kernel if this one has no Wi-Fi driver
After=local-fs.target
Before=display-manager.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mintosh-bootcheck
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable mintosh-bootcheck
fi
# Ubuntu shows the menu for 10 s after a start that didn't finish (GRUB_TIMEOUT=0 would hide it then too)
grep -q GRUB_RECORDFAIL_TIMEOUT /etc/default/grub.d/90-mintosh-default.cfg 2>/dev/null \
  || echo 'GRUB_RECORDFAIL_TIMEOUT=10' >> /etc/default/grub.d/90-mintosh-default.cfg
update-grub

log "Firewall: nothing on the network can connect in; SSH with keys only"
apt-get install -y ufw
ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
# The helper connected over SSH right now keeps access until tools/close-access.sh
for ip in $(ss -Htn state established '( sport = :22 )' | awk '{print $4}' | sed -E 's/:[0-9]+$//; s/^\[|\]$//g' | sort -u); do
  ufw allow from "$ip" to any port 22 proto tcp comment mintosh-helper >/dev/null
done
ufw --force enable
if ls /home/*/.ssh/authorized_keys >/dev/null 2>&1; then   # a key is in place (0-send-from-mac), so no lock-out
  printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' > /etc/ssh/sshd_config.d/50-mintosh.conf
  systemctl reload ssh 2>/dev/null || true
fi

log "Done. Reboot, then run 2-restore-files.sh as the normal user (no sudo)."
