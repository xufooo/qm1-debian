#!/usr/bin/env python3
"""Run the real firstboot script with isolated disks and account commands."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1] / 'overlay/usr/local/sbin/qm1-firstboot'
HASH = '$6$fixture$' + 'a' * 86
MOCK = r'''#!/usr/bin/env python3
import os, pathlib, shutil, sys
b=pathlib.Path(os.environ['FIXTURE']); cmd=pathlib.Path(sys.argv[0]).name; a=sys.argv[1:]
with (b/'calls').open('a') as f: f.write(cmd+' '+' '.join(a)+'\n')
if cmd=='readlink': print(a[-1]); sys.exit(0)
if cmd=='id': print('0'); sys.exit(0)
if cmd=='findmnt': print('/dev/sda2'); sys.exit(0)
if cmd=='blkid':
    if a[-1]=='/dev/sda1': print('c12a7328-f81f-11d2-ba4b-00a0c93ec93b')
    else: print('0fc63daf-8483-4772-8e79-3d69d8477de4')
    sys.exit(0)
if cmd=='lsblk':
    if any('PKNAME' in x for x in a):
        if os.environ['CASE']!='whole': print('/dev/sda')
    elif any(x=='TYPE' for x in a): print('disk')
    elif a[-1:] == ['/dev/sda']:
        print('/dev/sda')
        if os.environ['CASE']!='missing':
            print('/dev/sda1 part' if 'PATH,TYPE' in a else '/dev/sda1')
        print('/dev/sda2 part' if 'PATH,TYPE' in a else '/dev/sda2')
    elif any('LABEL' in x for x in a):
        if os.environ['CASE']=='duplicate': print('QM1ESP /dev/mmcblk0p1')
        else: print('VOID /dev/mmcblk0p1')
    else:
        print('c12a7328-f81f-11d2-ba4b-00a0c93ec93b /dev/mmcblk0p1')
        print('c12a7328-f81f-11d2-ba4b-00a0c93ec93b /dev/sda1')
elif cmd=='mountpoint': sys.exit(0 if (b/'mounted').exists() else 1)
elif cmd=='mount':
    if os.environ['CASE']=='mountfail': sys.exit(1)
    dest=pathlib.Path(a[-1]); dest.mkdir(parents=True,exist_ok=True)
    source=b/('usb' if a[-2]=='/dev/sda1' else 'void')
    shutil.copytree(source,dest,dirs_exist_ok=True); (b/'mounted').touch()
elif cmd=='umount': (b/'mounted').unlink(missing_ok=True)
elif cmd=='chpasswd': (b/'password-applied').write_text(sys.stdin.read())
elif cmd=='systemctl': pass
else: sys.exit('unexpected mock '+cmd)
'''

def run(case):
    with tempfile.TemporaryDirectory(prefix='qm1-firstboot-') as tmp:
        b = Path(tmp)
        for disk in ('usb', 'void'):
            p = b / disk / 'qm1/provision'
            p.mkdir(parents=True)
            (p / 'ssh').touch()
        p = b / 'usb/qm1/provision'
        (p / 'ssh_user').write_text('qm1\n')
        (p / 'ssh_password_hash').write_text(HASH + '\n')
        if case == 'local':
            shutil_source = b / 'usb/qm1/provision'
            shutil.copytree(shutil_source, b / 'root/etc/qm1/provision')
        commands = b / 'bin'
        commands.mkdir()
        for cmd in ('readlink', 'id', 'findmnt', 'lsblk', 'blkid', 'mountpoint', 'mount', 'umount', 'chpasswd', 'systemctl'):
            f = commands / cmd
            f.write_text(MOCK)
            f.chmod(0o755)
        script = re.sub(r'/(?:etc|root|run|var/lib)/',
                        lambda m: str(b / 'root') + m.group(0), SOURCE.read_text())
        f = b / 'firstboot'
        f.write_text(script)
        env = dict(os.environ, FIXTURE=tmp, CASE=case, PATH=str(commands)+':'+os.environ['PATH'])
        r = subprocess.run(['bash', str(f)], env=env, text=True, capture_output=True, errors='replace', timeout=30)
        applied = b / 'password-applied'
        marker = b / 'root/var/lib/qm1/firstboot-done'
        calls = (b / 'calls').read_text()
        assert 'mount -o ro /dev/mmcblk0p1' not in calls, case + ': selected unrelated Void ESP'
        if case in ('missing', 'mountfail'):
            assert r.returncode != 0 and not applied.exists() and not marker.exists(), r.stdout+r.stderr
        elif case == 'whole':
            assert r.returncode == 0 and not applied.exists() and not marker.exists()
            assert 'mount -o' not in calls
        else:
            assert r.returncode == 0, r.stdout+r.stderr
            assert applied.exists(), case + ': login password was not applied'
            assert applied.read_text() == 'qm1:' + HASH + '\n'
            assert marker.exists()
            assert HASH not in r.stdout+r.stderr
        print('PASS', case)

for scenario in ('mixed', 'duplicate', 'missing', 'mountfail', 'whole', 'local'):
    run(scenario)
