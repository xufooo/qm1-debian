#!/usr/bin/env bash
# Full installation tests use disposable disks and a private test copy of the
# ISO. The production installer never contains this automatic partition seed.
set -euo pipefail
OUT="$(realpath "${1:?usage: test-official-installer.sh BUILD_DIR}")"
ISO="$OUT/qm1-debian-installer-amd64.iso"
TESTS="$OUT/tests"
mkdir -p "$TESTS"
for arch in ia32 x64; do
    work="$TESTS/$arch"
    mkdir -p "$work/ram"
    xorriso -osirrox on -indev "$ISO" -extract /install.amd/initrd.gz "$work/initrd.gz" > "$work/extract.log" 2>&1
    ( cd "$work/ram"; gzip -dc "$work/initrd.gz" | cpio -id --quiet --no-absolute-filenames )
    # Public, disposable VM account. No real credentials enter CI artifacts.
    hash="$(printf '%s' 'qm1-ci-fixture' | openssl passwd -6 -stdin)"
    cat >> "$work/ram/preseed.cfg" <<EOF

d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string qm1-test
d-i netcfg/get_domain string test.invalid
d-i netcfg/wireless_wep string
d-i hw-detect/load_firmware boolean false
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i clock-setup/utc boolean true
d-i time/zone string Etc/UTC
d-i clock-setup/ntp boolean false
d-i passwd/root-login boolean false
d-i passwd/user-fullname string QM1 Installer Test
d-i passwd/username string qm1fixture
d-i passwd/user-password-crypted password $hash
d-i partman-auto/disk string /dev/vda
d-i partman-auto/method string regular
d-i partman-partitioning/choose_label select gpt
d-i partman-partitioning/default_label string gpt
d-i partman-auto/choose_recipe select atomic
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman/choose_partition select finish
d-i partman/confirm_write_new_label boolean true
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i apt-setup/cdrom/set-first boolean false
d-i pkgsel/run_tasksel boolean false
d-i pkgsel/upgrade select none
popularity-contest popularity-contest/participate boolean false
d-i preseed/late_command string /bin/sh /qm1-test-target.sh
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/poweroff boolean true
EOF
    cat > "$work/ram/qm1-test-target.sh" <<'EOF'
#!/bin/sh
set -eu
/bin/sh /cdrom/qm1/install-target.sh
# VM-only serial console; production UART stays available for Bluetooth.
mkdir -p /target/etc/default/grub.d
printf 'GRUB_CMDLINE_LINUX="console=ttyS0,115200n8"\nGRUB_TIMEOUT=1\n' > /target/etc/default/grub.d/99-qm1-ci.cfg
in-target update-grub
cat > /target/usr/local/sbin/qm1-ci-check <<'CHECK'
#!/bin/sh
set -eu
test -f /etc/qm1-installation
dpkg-query -W qm1-board-support qm1-rtw88-8723bs
modprobe rtw88_qm1
find /boot/efi/EFI -type f
if dmesg | grep -E 'Unknown symbol|disagrees about version'; then exit 1; fi
if [ -n "$(systemctl --failed --no-legend --plain)" ]; then systemctl --failed; exit 1; fi
echo QM1_SUDO_DRIVER_OK
CHECK
chmod 0755 /target/usr/local/sbin/qm1-ci-check
printf 'QM1_OFFICIAL_INSTALL_COMPLETE\n' > /dev/console
EOF
    chmod 0755 "$work/ram/qm1-test-target.sh"
    ( cd "$work/ram"; find . -print0 | cpio --null -o -H newc --quiet | gzip -n -1 ) > "$work/test-initrd.gz"
    rm -rf "$work/ram" "$work/initrd.gz"
    cat > "$work/grub.cfg" <<'EOF'
serial --unit=0 --speed=115200
terminal_input serial
terminal_output serial
set default=0
set timeout=1
menuentry 'QM1 disposable full Debian installation test' {
    linux /install.amd/vmlinuz auto=true priority=critical console=ttyS0,115200n8 DEBIAN_FRONTEND=text intel_idle.max_cstate=1 ---
    initrd /install.amd/initrd.gz
}
EOF
    xorriso -indev "$ISO" -outdev "$work/test.iso" -boot_image any replay \
        -map "$work/grub.cfg" /boot/grub/grub.cfg \
        -map "$work/test-initrd.gz" /install.amd/initrd.gz \
        -commit -end > "$work/remaster.log" 2>&1
    qemu-img create -f qcow2 "$work/target.qcow2" 12G
    if [ "$arch" = ia32 ]; then stem=OVMF32; else stem=OVMF; fi
    code="/usr/share/OVMF/${stem}_CODE_4M.fd"
    vars="/usr/share/OVMF/${stem}_VARS_4M.fd"
    test -s "$code"; test -s "$vars"
    cp "$vars" "$work/vars.fd"
    accel=tcg
    [ ! -r /dev/kvm ] || accel=kvm
    vm=(qemu-system-x86_64 -machine "q35,accel=$accel" -cpu max -m 2048 -smp 2
        -display none -monitor none -no-reboot
        -drive "if=pflash,format=raw,readonly=on,file=$code"
        -drive "if=pflash,format=raw,file=$work/vars.fd"
        -drive "if=virtio,format=qcow2,file=$work/target.qcow2"
        -device qemu-xhci -netdev user,id=n0 -device virtio-net-pci,netdev=n0)
    # A removable USB disk, not QEMU's easier CD-ROM boot route.
    timeout --signal=TERM 2400 "${vm[@]}" -serial "file:$work/install.log" \
        -drive "if=none,id=install,format=raw,readonly=on,file=$work/test.iso" \
        -device usb-storage,drive=install,bootindex=1
    grep -q QM1_OFFICIAL_INSTALL_COMPLETE "$work/install.log"
    ! grep -Eq 'QM1_INSTALLER_WIFI_MODULE_FAILED|disagrees about version of symbol|Unknown symbol' "$work/install.log"
    grep -q QM1_INSTALLER_WIFI_MODULE_LOADED "$work/install.log"
    # Fresh firmware variables and no USB: requires the installed disk's EFI
    # fallback path as well as the normal user's real PAM password and sudo.
    cp "$vars" "$work/vars.fd"
    export QM1_CI_ARCH="$arch" QM1_CI_WORK="$work"
    expect -f /dev/stdin "${vm[@]}" -serial stdio <<'EOF'
set timeout 300
log_file -noappend "$env(QM1_CI_WORK)/installed-login.log"
spawn {*}$argv
expect {
    -re {login: $} {send "qm1fixture\r"}
    timeout {exit 1}
    eof {exit 1}
}
expect "Password:"
send "qm1-ci-fixture\r"
expect {
    -re {\$ $} {}
    "Login incorrect" {exit 1}
    timeout {exit 1}
    eof {exit 1}
}
send "id -un; printf 'QM1_PAM_%s\\n' LOGIN_OK\r"
expect -re {qm1fixture[\r\n]+QM1_PAM_LOGIN_OK}
send "sudo -k; sudo -S /usr/local/sbin/qm1-ci-check\r"
expect -re {password for qm1fixture:}
send "qm1-ci-fixture\r"
expect "QM1_SUDO_DRIVER_OK\r\n"
send "sudo poweroff\r"
expect eof
set result [wait]
exit [lindex $result 3]
EOF
    grep -q QM1_PAM_LOGIN_OK "$work/installed-login.log"
    grep -q QM1_SUDO_DRIVER_OK "$work/installed-login.log"
    if [ "$arch" = ia32 ]; then loader=BOOTIA32.EFI; else loader=BOOTX64.EFI; fi
    grep -qi "$loader" "$work/installed-login.log"
    ! grep -Eq 'Unknown symbol|disagrees about version' "$work/installed-login.log"
    rm -f "$work/test.iso" "$work/test-initrd.gz" "$work/target.qcow2"
    echo "PASS $arch USB EFI -> complete Debian installation -> USB removed -> normal password/sudo/driver"
done
