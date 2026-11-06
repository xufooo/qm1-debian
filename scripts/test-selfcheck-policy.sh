#!/usr/bin/env bash
# Exercise the shipped reporting policy without reading the host's hardware.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 - "$SCRIPT_DIR/drv-selfcheck.sh" <<'PY'
import pathlib
import subprocess
import sys
text = pathlib.Path(sys.argv[1]).read_text()
prefix = text[:text.index('# 一次性把 dmesg')]
checks = r'''
row WARN "蓝牙" "missing"
[ "$FAIL" -eq 0 ] && [ "$WARN" -eq 1 ] || exit 10
STRICT=1
row WARN "蓝牙" "missing"
row WARN "时间同步" "unsynchronized"
[ "$FAIL" -eq 2 ] && [ "$WARN" -eq 1 ] || exit 11
row INFO "应用安装" "not installed"
[ "$FAIL" -eq 2 ] && [ "$WARN" -eq 1 ] || exit 12
row WARN "USB 备份网卡" "not connected"
[ "$WARN" -eq 2 ] || exit 13
'''
subprocess.run(['bash', '-c', prefix + checks], check=True, stdout=subprocess.DEVNULL)
# The actual root-filesystem branch must accept rw even when another
# mount option contains the text "ro", and reject an explicit ro option.
start = text.index('if findmnt -no SOURCE /')
end = text.index('# eMMC / SD 控制器', start)
branch = text[start:end]
for options, fails in [('rw,noatime,errors=remount-ro', 0), ('ro,noatime', 1)]:
    mock = '''
findmnt() {
    case "$2" in
        SOURCE) echo /dev/example ;;
        FSTYPE) echo ext4 ;;
        OPTIONS) printf '%s\\n' "$MOUNT_OPTIONS" ;;
    esac
}
'''
    script = prefix + mock + '\nMOUNT_OPTIONS=' + repr(options) + '\n' + branch
    script += '\n[ "$FAIL" -eq ' + str(fails) + ' ]'
    subprocess.run(['bash', '-c', script], check=True, stdout=subprocess.DEVNULL)
print('PASS strict required-function policy, optional applications, exact rw/ro mount option')
PY
