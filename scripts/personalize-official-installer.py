#!/usr/bin/env python3
"""Add a private d-i account seed locally; retain interactive disk confirmation."""
import argparse
import gzip
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile


def newc_file(name, data, inode=1):
    name = name.encode() + b'\0'
    fields = [inode, 0o100600, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(name), 0]
    header = b'070701' + ''.join(f'{n:08x}' for n in fields).encode()
    prefix = header + name
    return prefix + b'\0' * (-len(prefix) % 4) + data + b'\0' * (-len(data) % 4)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('iso', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--login-hash-file', required=True, type=Path)
    parser.add_argument('--user', default='qm1')
    parser.add_argument('--authorized-keys', type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r'[a-z][a-z0-9_-]{0,30}', args.user):
        parser.error('invalid login username')
    password_hash = args.login_hash_file.read_text().strip()
    if not re.fullmatch(r'\$6\$(?:rounds=[0-9]+\$)?[./A-Za-z0-9]{1,16}\$[./A-Za-z0-9]{86}', password_hash):
        parser.error('expected one SHA512-crypt hash, never a plaintext password')
    source, output = args.iso.resolve(), args.output.resolve()
    if output.exists() or source == output:
        parser.error('output must be a new file')
    output.parent.mkdir(parents=True, exist_ok=True)
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix='qm1-private-', dir=output.parent) as directory:
        work = Path(directory)
        log = (work / 'remaster.log').open('w')

        def xorriso(*parameters):
            subprocess.run(['xorriso', *map(str, parameters)], check=True, stdout=log, stderr=log)

        for item in ('qm1/preseed.cfg', 'md5sum.txt', 'install.amd/initrd.gz', 'install.amd/gtk/initrd.gz'):
            target = work / item
            target.parent.mkdir(parents=True, exist_ok=True)
            xorriso('-osirrox', 'on', '-indev', source, '-extract', '/' + item, target)
        seed = (work / 'qm1/preseed.cfg').read_text()
        if re.search(r'^\s*d-i\s+(?:partman(?:-[a-z-]+)?|passwd)/', seed, re.M):
            raise ValueError('input must be the public, interactive installer')
        seed += ('\n# Private account only; disk selection and confirmation stay interactive.\n'
                 'd-i passwd/root-login boolean false\n'
                 f'd-i passwd/user-fullname string {args.user}\n'
                 f'd-i passwd/username string {args.user}\n'
                 f'd-i passwd/user-password-crypted password {password_hash}\n')
        archive = newc_file('preseed.cfg', seed.encode()) + newc_file('TRAILER!!!', b'', 0)
        archive += b'\0' * (-len(archive) % 512)
        files = {}
        for item in ('install.amd/initrd.gz', 'install.amd/gtk/initrd.gz'):
            target = work / item
            # The kernel supports concatenated compressed newc initramfs
            # archives; the last preseed replaces the public hardware seed.
            with target.open('ab') as stream:
                stream.write(gzip.compress(archive, mtime=0))
            files[item] = target
        if args.authorized_keys:
            keys = args.authorized_keys.read_text()
            if not keys.strip() or any(not line.startswith(('ssh-ed25519 ', 'ssh-rsa ', 'ecdsa-sha2-'))
                                       for line in keys.splitlines() if line.strip()):
                raise ValueError('expected plain SSH public keys')
            private = work / 'private'
            private.mkdir()
            (private / 'authorized_keys').write_text(keys.rstrip() + '\n')
            (private / 'ssh_user').write_text(args.user + '\n')
            files['qm1/private/authorized_keys'] = private / 'authorized_keys'
            files['qm1/private/ssh_user'] = private / 'ssh_user'
        checksums = []
        for line in (work / 'md5sum.txt').read_text().splitlines():
            digest, name = line.split(maxsplit=1)
            item = name.removeprefix('./')
            if item in files:
                digest = hashlib.md5(files[item].read_bytes()).hexdigest()
            checksums.append(f'{digest}  {name}')
        for item, target in files.items():
            if item.startswith('qm1/private/'):
                checksums.append(f'{hashlib.md5(target.read_bytes()).hexdigest()}  ./{item}')
        (work / 'md5sum.txt').write_text('\n'.join(checksums) + '\n')
        files['md5sum.txt'] = work / 'md5sum.txt'
        command = ['-indev', source, '-outdev', output, '-boot_image', 'any', 'replay']
        for item, target in files.items():
            command += ['-map', target, '/' + item]
        command += ['-commit', '-end']
        try:
            xorriso(*command)
        except subprocess.CalledProcessError:
            output.unlink(missing_ok=True)
            raise RuntimeError('private remaster failed; public input remains unchanged') from None
    output.chmod(0o600)
    digest = hashlib.file_digest(output.open('rb'), 'sha512').hexdigest()
    output.with_suffix(output.suffix + '.sha512').write_text(f'{digest}  {output.name}\n')
    print('Created private official installer; account configuration added, partitioning remains interactive.')


if __name__ == '__main__':
    main()
