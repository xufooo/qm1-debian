#!/usr/bin/env bash
# Remix the complete authenticated Debian-Installer, retaining upstream menus,
# initrds and hybrid boot layout. This is not a deployed root filesystem image.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="build/official-installer"
WIFI_DEB=""
SOURCE_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --out-dir) OUT="$2"; shift 2 ;;
        --source-dir) SOURCE_DIR="$2"; shift 2 ;;
        --wifi-deb) WIFI_DEB="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done
[ -f "$WIFI_DEB" ] || { echo 'matching reviewed Wi-Fi package is required' >&2; exit 1; }
WIFI_DEB="$(realpath "$WIFI_DEB")"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
SOURCE_DIR="${SOURCE_DIR:-$OUT/source}"
bash "$SCRIPT_DIR/fetch-debian-installer.sh" "$SOURCE_DIR"
ISO="$(cat "$SOURCE_DIR/iso-path.txt")"
WORK="$(mktemp -d "$OUT/work.XXXXXX")"
TREE="$WORK/tree"
mkdir "$TREE"
xorriso -osirrox on -indev "$ISO" -extract / "$TREE" > "$OUT/extract.log" 2>&1
chmod -R u+w "$TREE"
KVER="$(file -b "$TREE/install.amd/vmlinuz" | sed -nE 's/.*version ([^ ]+).*/\1/p')"
[[ "$KVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+deb[0-9]+-amd64$ ]] || { echo 'unsupported installer kernel ABI' >&2; exit 1; }
[ -f "/usr/src/linux-headers-$KVER/Module.symvers" ] || { echo "missing official headers: $KVER" >&2; exit 1; }
printf '%s\n' "$KVER" > "$OUT/kernel-abi.txt"

# Use Debian's own complete CD bootloader, not a hand-selected grub-mkimage.
shopt -s nullglob
ia32_unsigned=("$TREE"/pool/main/g/grub2/grub-efi-ia32-unsigned_*_amd64.deb)
ia32_bin=("$TREE"/pool/main/g/grub2/grub-efi-ia32-bin_*_amd64.deb)
x64_bin=("$TREE"/pool/main/g/grub2/grub-efi-amd64-bin_*_amd64.deb)
[ "${#ia32_unsigned[@]}:${#ia32_bin[@]}:${#x64_bin[@]}" = 1:1:1 ] || { echo 'ambiguous official GRUB packages' >&2; exit 1; }
mkdir "$WORK/grub"
for deb in "${ia32_unsigned[@]}" "${ia32_bin[@]}" "${x64_bin[@]}"; do dpkg-deb -x "$deb" "$WORK/grub"; done
GCD="$WORK/grub/usr/lib/grub/i386-efi/monolithic/gcdia32.efi"
grub-file --is-i386-efi "$GCD"
for arch in i386 x86_64; do
    mkdir -p "$TREE/boot/grub/$arch-efi"
    cp -a "$WORK/grub/usr/lib/grub/$arch-efi/." "$TREE/boot/grub/$arch-efi/"
    rm -rf "$TREE/boot/grub/$arch-efi/monolithic"
    printf 'source /boot/grub/grub.cfg\n' > "$TREE/boot/grub/$arch-efi/grub.cfg"
done

# Give the derivative its own media identity so another Debian disk cannot
# satisfy the firmware loader's search. Preserve the official bootstrap form.
old_id="$(find "$TREE/.disk/id" -maxdepth 1 -type f -printf '%f\n')"
[ -n "$old_id" ] && [ "$(printf '%s\n' "$old_id" | wc -l)" = 1 ]
new_id="$(python3 -c 'import uuid;print(uuid.uuid4())')"
mv "$TREE/.disk/id/$old_id" "$TREE/.disk/id/$new_id"
sed -i "s|/.disk/id/$old_id|/.disk/id/$new_id|g" "$TREE/EFI/debian/grub.cfg"
printf '\nQM1 adaptation of the official Debian installer\n' >> "$TREE/.disk/info"
mkdir "$WORK/efi-files"
mcopy -s -i "$TREE/boot/grub/efi.img" ::/EFI "$WORK/efi-files/"
cp "$TREE/EFI/debian/grub.cfg" "$WORK/efi-files/EFI/debian/grub.cfg"
cp "$TREE/EFI/debian/grub.cfg" "$WORK/efi-files/EFI/boot/grub.cfg"
cp "$GCD" "$WORK/efi-files/EFI/boot/bootia32.efi"
truncate -s 16M "$WORK/efi.img"
mkfs.vfat -F 16 -n QM1EFI "$WORK/efi.img" >/dev/null
mcopy -s -i "$WORK/efi.img" "$WORK/efi-files/EFI" ::/
cp "$WORK/efi.img" "$TREE/boot/grub/efi.img"
mdir -/ -i "$TREE/boot/grub/efi.img" ::/EFI > "$OUT/efi-files.txt"

# Keep every upstream install/expert/rescue path. Firmware text output avoids
# the unsupported GOP video mode seen on the physical QM1.
sed -i -e 's/terminal_output gfxterm/terminal_output console/' -e 's/set gfxpayload=keep/set gfxpayload=text/g' -e '/^[[:space:]]*linux[[:space:]]/s/ ---/ intel_idle.max_cstate=1 ---/' "$TREE/boot/grub/grub.cfg"
while IFS= read -r cfg; do
    sed -i '/^[[:space:]]*append[[:space:]]/s/ ---/ intel_idle.max_cstate=1 ---/' "$cfg"
done < <(find "$TREE/isolinux" -name '*.cfg')
sed -i '1i set default=1' "$TREE/boot/grub/grub.cfg"
cat >> "$TREE/boot/grub/grub.cfg" <<'EOF'

if [ "$grub_platform" = "efi" ]; then
    insmod efifwsetup
    if fwsetup --is-supported; then
        menuentry "UEFI Firmware Settings" { fwsetup; }
    fi
fi
EOF
grub-script-check "$TREE/boot/grub/grub.cfg"

# Extract the exact official kernel to resolve the complete module closure.
kernel_debs=("$TREE"/pool/main/l/linux-signed-amd64/linux-image-"$KVER"_*_amd64.deb)
[ "${#kernel_debs[@]}" = 1 ] || { echo 'matching ISO kernel package missing' >&2; exit 1; }
mkdir "$WORK/kernel" "$WORK/wifi"
dpkg-deb -x "${kernel_debs[0]}" "$WORK/kernel"
dpkg-deb -x "$WIFI_DEB" "$WORK/wifi"
MODULE="$WORK/wifi/lib/modules/$KVER/extra/rtw88/rtw88_qm1.ko"
[ -f "$MODULE" ]
[ "$(modinfo -F vermagic "$MODULE" | cut -d' ' -f1)" = "$KVER" ]
[ "$(dpkg-deb -f "${kernel_debs[0]}" Version)" = "$(dpkg-query -W -f='${Version}' "linux-headers-$KVER")" ]
# Module import CRCs must match the official matching headers as well.
modprobe --show-modversions "$MODULE" > "$OUT/wifi-import-crcs.txt"
python3 - "$OUT/wifi-import-crcs.txt" "/usr/src/linux-headers-$KVER/Module.symvers" <<'PY'
import pathlib,sys
expected={p[1]:int(p[0],16) for l in pathlib.Path(sys.argv[2]).read_text().splitlines() if len(p:=l.split())>=2}
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    crc,name=line.split()[:2]
    assert expected.get(name)==int(crc,16), 'module symbol CRC mismatch: '+name
print('PASS driver symbol CRCs match the official installer kernel headers')
PY
[ -f "$WORK/kernel/boot/config-$KVER" ]
grep -qx 'CONFIG_EFI_MIXED=y' "$WORK/kernel/boot/config-$KVER"
if [ ! -e "$WORK/kernel/lib" ]; then ln -s usr/lib "$WORK/kernel/lib"; fi
MODULE_ROOT="$WORK/kernel/lib/modules/$KVER"
[ -d "$MODULE_ROOT" ]
mkdir -p "$MODULE_ROOT/extra/rtw88"
cp "$MODULE" "$MODULE_ROOT/extra/rtw88/"
depmod -b "$WORK/kernel" "$KVER"
modprobe -d "$WORK/kernel" -S "$KVER" --show-depends rtw88_qm1 > "$OUT/installer-module-closure.txt"

# Add the same driver and firmware to both text and GTK installer RAM disks.
for image in "$TREE/install.amd/initrd.gz" "$TREE/install.amd/gtk/initrd.gz"; do
    ram="$(mktemp -d "$WORK/initrd.XXXXXX")"
    ( cd "$ram"; gzip -dc "$image" | cpio -id --quiet --no-absolute-filenames )
    [ -d "$ram/usr/lib/modules/$KVER" ]
    [ "$(readlink "$ram/lib")" = usr/lib ] || { echo 'unexpected installer usrmerge layout' >&2; exit 1; }
    while read -r action module_file _; do
        [ "$action" = insmod ] || continue
        case "$module_file" in "$WORK/kernel/lib/modules/$KVER/"*) ;; *) echo 'unexpected module closure path' >&2; exit 1 ;; esac
        relative="${module_file#"$WORK/kernel/lib/modules/$KVER/"}"
        install -D -m 0644 "$module_file" "$ram/usr/lib/modules/$KVER/$relative"
    done < "$OUT/installer-module-closure.txt"
    # Algorithm modules are requested dynamically by mac80211/WPA, not all
    # represented in ELF depends=. Include the official crypto module sets.
    for folder in crypto arch/x86/crypto lib/crypto; do
        [ -d "$MODULE_ROOT/kernel/$folder" ] || continue
        while IFS= read -r algorithm; do
            relative="${algorithm#"$MODULE_ROOT/"}"
            install -D -m 0644 "$algorithm" "$ram/usr/lib/modules/$KVER/$relative"
        done < <(find "$MODULE_ROOT/kernel/$folder" -name '*.ko*')
    done
    mkdir -p "$ram/usr/lib/firmware/rtw88" "$ram/etc/modprobe.d" "$ram/usr/lib/udev/rules.d"
    cp "$WORK/wifi/lib/firmware/rtw88/"* "$ram/usr/lib/firmware/rtw88/"
    cp "$WORK/wifi/etc/modprobe.d/"* "$ram/etc/modprobe.d/"
    cp "$REPO/overlay/etc/udev/rules.d/60-qm1-emmc-power.rules" "$ram/usr/lib/udev/rules.d/"
    mkdir -p "$ram/lib/debian-installer-startup.d"
    cat > "$ram/lib/debian-installer-startup.d/S55qm1-wifi" <<'EOF'
#!/bin/sh
if modprobe rtw88_qm1; then
    echo 'QM1_INSTALLER_WIFI_MODULE_LOADED' > /dev/console
else
    echo 'QM1_INSTALLER_WIFI_MODULE_FAILED' > /dev/console
fi
EOF
    chmod 0755 "$ram/lib/debian-installer-startup.d/S55qm1-wifi"
    cp "$MODULE_ROOT/modules.builtin" "$MODULE_ROOT/modules.builtin.modinfo" "$ram/usr/lib/modules/$KVER/"
    depmod -b "$ram" "$KVER"
    ( cd "$ram"; find . -print0 | cpio --null -o -H newc --quiet | gzip -n -9 ) > "$image.new"
    mv "$image.new" "$image"
    rm -rf "$ram"
done

# Build an offline local repository for the target's board packages. Official
# d-i continues to own partitioning, user/password creation and EFI setup.
mkdir -p "$TREE/qm1/packages/partial"
bash "$SCRIPT_DIR/package-board-support.sh" "$TREE/qm1/packages"
cp "$WIFI_DEB" "${kernel_debs[0]}" "$TREE/qm1/packages/"
apt-get -y --download-only --no-install-recommends \
    -o Dir::State::status=/dev/null -o Dir::Cache::archives="$TREE/qm1/packages" \
    install firmware-realtek bluez zram-tools systemd-oomd alsa-utils iw rfkill kmod iproute2 \
    pciutils usbutils python3 python3-venv curl ca-certificates openssh-server sudo init-system-helpers \
    "linux-image-$KVER=$(dpkg-deb -f "${kernel_debs[0]}" Version)"
rm -rf "$TREE/qm1/packages/partial" "$TREE/qm1/packages/lock"
( cd "$TREE/qm1/packages"; dpkg-scanpackages . /dev/null | gzip -n > Packages.gz )
install -m 0755 "$SCRIPT_DIR/official-installer-target.sh" "$TREE/qm1/install-target.sh"
install -m 0755 "$SCRIPT_DIR/verify-board-modules.sh" "$TREE/qm1/verify-board-modules.sh"
printf 'Debian-Installer QM1 adaptation\nkernel=%s\n' "$KVER" > "$TREE/qm1/installer-version"
cat > "$TREE/qm1/preseed.cfg" <<EOF
# Hardware setup only: preserve normal interactive partition/account screens.
d-i base-installer/kernel/image string linux-image-$KVER
d-i grub-installer/force-efi-extra-removable boolean true
d-i apt-setup/non-free-firmware boolean true
d-i preseed/late_command string /bin/sh /cdrom/qm1/install-target.sh
EOF
# Embed this limited preseed in the installer initrd, which loads preseed.cfg
# before its normal main menu. It contains no disk selection or passwords.
for image in "$TREE/install.amd/initrd.gz" "$TREE/install.amd/gtk/initrd.gz"; do
    preseed_root="$(mktemp -d "$WORK/preseed.XXXXXX")"
    cp "$TREE/qm1/preseed.cfg" "$preseed_root/preseed.cfg"
    ( cd "$preseed_root"; find . -print0 | cpio --null -o -H newc --quiet | gzip -n ) >> "$image"
    rm -rf "$preseed_root"
done
! grep -Eq 'partman/(confirm|confirm_nooverwrite)|partman-auto/disk|passwd/.*password' "$TREE/qm1/preseed.cfg"
( cd "$TREE"; find . -type f ! -path './md5sum.txt' ! -path './md5sum.txt.new' ! -path './isolinux/boot.cat' -print0 | sort -z | xargs -0 md5sum > md5sum.txt.new; mv md5sum.txt.new md5sum.txt )
OUTPUT="$OUT/qm1-debian-installer-amd64.iso"
# The official netinst exposes its in-ISO EFI image through hybrid GPT; it
# does not append an EFI partition. Preserve the BIOS boot inode and replay
# the original layout after updating changed files, including the larger FAT.
xorriso -indev "$ISO" -outdev "$OUTPUT" -update_r "$TREE" / \
    -boot_image any replay \
    -commit -end > "$OUT/remaster.log" 2>&1
xorriso -indev "$OUTPUT" -report_el_torito plain -report_system_area plain > "$OUT/boot-layout.txt" 2>&1
( cd "$OUT"; sha512sum "$(basename "$OUTPUT")" > SHA512SUMS )
printf '%s\n' "$WORK" > "$OUT/work-tree.txt"
echo "Built complete official-based installer: $OUTPUT"
