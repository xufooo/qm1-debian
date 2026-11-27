#!/usr/bin/env python3
"""Reject custom board files that collide with Debian package-owned files."""
import argparse
from pathlib import Path
import subprocess
import tarfile


def paths(package):
    process = subprocess.Popen(['dpkg-deb', '--fsys-tarfile', str(package)], stdout=subprocess.PIPE)
    result = set()
    with tarfile.open(fileobj=process.stdout, mode='r|') as archive:
        for item in archive:
            if item.isdir():
                continue
            name = item.name.removeprefix('./').lstrip('/')
            for old, new in (('lib/', 'usr/lib/'), ('lib64/', 'usr/lib64/'),
                             ('bin/', 'usr/bin/'), ('sbin/', 'usr/sbin/')):
                if name.startswith(old):
                    name = new + name[len(old):]
                    break
            result.add(name)
    process.stdout.close()
    if process.wait():
        raise RuntimeError('cannot inspect Debian archive: ' + package.name)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('packages', type=Path)
    args = parser.parse_args()
    packages = sorted(args.packages.glob('*.deb'))
    custom = [p for p in packages if p.name.startswith(('qm1-board-support_', 'qm1-rtw88-8723bs_'))]
    if len(custom) != 2:
        raise RuntimeError('expected board and reviewed Wi-Fi packages')
    owners = {}
    for package in custom:
        for path in paths(package):
            if path in owners:
                raise RuntimeError('custom packages both own /' + path)
            owners[path] = package.name
    for package in packages:
        if package in custom:
            continue
        overlap = owners.keys() & paths(package)
        if overlap:
            raise RuntimeError('custom package ownership conflicts with ' + package.name + ': ' +
                               ', '.join('/' + path for path in sorted(overlap)))
    print('PASS custom board/Wi-Fi packages do not overwrite Debian-owned files (usrmerge normalized)')


if __name__ == '__main__':
    main()
