#!/usr/bin/env bash
# Regress real audit failures: built-ins reported as modules, and early cpio.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 - "$SCRIPT_DIR" <<'PY'
import gzip
import importlib.util
import lzma
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
scripts = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('initramfs', scripts/'lib/list-initramfs.py')
parser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parser)


def archive(entries):
    data = bytearray()
    for name, content in entries + [('TRAILER!!!', b'')]:
        encoded = name.encode() + b'\0'
        fields = [1, 0o100644, 0, 0, 1, 0, len(content), 0, 0, 0, 0, len(encoded), 0]
        data += b'070701' + ''.join(f'{v:08x}' for v in fields).encode() + encoded
        data += b'\0' * (-len(data) % 4)
        data += content
        data += b'\0' * (-len(data) % 4)
    return bytes(data) + b'\0' * (-len(data) % 512)


rule = 'usr/lib/udev/rules.d/60-qm1-emmc-power.rules'
early = archive([('kernel/x86/microcode/GenuineIntel.bin', b'fixture')])
main = archive([(rule, b'ACTION=="add"'), ('ordinary.txt', b'fixture')])
for compressor in [lambda data: data, gzip.compress, lzma.compress,
                   lambda data: subprocess.check_output(['zstd', '-q', '-c'], input=data)]:
    for prefix in [b'', early]:
        names = list(parser.list_entries(prefix + compressor(main)))
        assert rule in names and 'ordinary.txt' in names
assert rule not in list(parser.list_entries(archive([('decoy', rule.encode())])))
for malformed in [b'070701', main[:160], main + b'broken trailing archive']:
    try:
        list(parser.list_entries(malformed))
    except (ValueError, EOFError):
        pass
    else:
        raise AssertionError('malformed initramfs accepted')

hook = (scripts.parent/'hooks/customize02-drivers.sh').read_text()
start = hook.index('driver_state() {')
function = hook[start:hook.index('\n}\n', start) + 3]
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    config = root/'config'
    prefix = 'set -eu\n' + function + '\nTARGET="$1"; KCFG="$1/config"; KVER=fixture\n'
    # modinfo succeeds for an in-kernel driver, too. This used to say module.
    config.write_text('CONFIG_SERIAL_8250_DW=y\n')
    subprocess.run(['sh', '-c', prefix + 'chroot() { return 0; }; '
                    '[ "$(driver_state 8250_dw SERIAL_8250_DW)" = builtin ]', 'test', str(root)], check=True)
    config.write_text('CONFIG_SERIAL_8250_DW=m\n')
    for result, expected in [(0, 'module'), (1, 'absent')]:
        subprocess.run(['sh', '-c', prefix + f'chroot() {{ return {result}; }}; '
                        f'[ "$(driver_state 8250_dw SERIAL_8250_DW)" = {expected} ]', 'test', str(root)], check=True)
print('PASS built-in/module classification, early-cpio + raw/gzip/xz/zstd initramfs, decoy and malformed rejection')

builder = (scripts/'build-rootfs.sh').read_text()
mirror_code = builder[builder.index('MIRRORS=('):builder.index('if ! mmdebstrap')]
for suite in ['trixie', 'bookworm', 'sid']:
    env = dict(os.environ, SUITE=suite, MIRROR='https://deb.debian.org/debian',
               COMPONENTS='main,non-free-firmware')
    output = subprocess.check_output(['bash', '-c', mirror_code + '\nprintf "%s\\0" "${MIRRORS[@]}"'], env=env)
    mirrors = output.decode().strip('\0').split('\0')
    assert mirrors[0] == env['MIRROR']
    if suite == 'sid':
        assert len(mirrors) == 1
    else:
        assert mirrors[1] == f'deb {env["MIRROR"]} {suite}-updates main non-free-firmware'
        assert mirrors[2] == f'deb https://security.debian.org/debian-security {suite}-security main non-free-firmware'
print('PASS stable bootstrap includes persistent security/updates sources; sid does not get invented suites')
PY
