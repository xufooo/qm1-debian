#!/usr/bin/env python3
"""CI fixture: test /bin/login on a real PTY inside the disposable chroot."""
import os
import errno
import pty
import re
import select
import signal
import sys
import time

password = sys.stdin.readline().rstrip('\n')
assert password, 'fixture password missing'
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(LC_ALL='C', LANG='C', TERM='linux')
    os.execv('/bin/login', ['login', 'qm1'])

output = bytearray()
child_reaped = False
def wait_for(pattern, timeout=20):
    global child_reaped
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if re.search(pattern, output):
            return
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                data = os.read(fd, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                data = b''
            if not data:
                # login closes/reopens the slave around vhangup(). An EIO
                # during that gap is not EOF while the login process lives.
                finished, _ = os.waitpid(pid, os.WNOHANG)
                if finished:
                    child_reaped = True
                    break
                time.sleep(0.02)
                continue
            output.extend(data)
    transcript = output.decode(errors='replace').replace(password, '<redacted>')
    raise RuntimeError(f'console login did not reach {pattern!r}: {transcript[-3000:]!r}')

try:
    wait_for(rb'[Pp]assword:')
    os.write(fd, password.encode() + b'\n')
    output.clear()
    wait_for(rb'[$#] ')
    os.write(fd, b'id -un\n')
    output.clear()
    wait_for(rb'(?m)^qm1\r?$')
    os.write(fd, b'exit\n')
    print('PASS real console password login as qm1 on a PTY')
finally:
    os.close(fd)
    if not child_reaped:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
