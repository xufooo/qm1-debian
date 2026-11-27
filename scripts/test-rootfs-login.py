#!/usr/bin/env python3
"""CI fixture: test /bin/login on a real PTY inside the disposable chroot."""
import os
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
    os.execv('/bin/login', ['login', 'qm1'])

output = bytearray()
def wait_for(pattern, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if re.search(pattern, output):
            return
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            output.extend(data)
    raise RuntimeError('console login did not reach the expected state')

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
    try:
        os.kill(pid, signal.SIGHUP)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
