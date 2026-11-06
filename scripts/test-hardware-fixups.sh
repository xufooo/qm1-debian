#!/usr/bin/env bash
# Run the shipped fixups against an isolated sysfs fixture, never the host.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 - "$SCRIPT_DIR/../overlay/usr/local/sbin/qm1-hardware-fixups" \
    "$SCRIPT_DIR/../overlay/usr/local/sbin/qm1-wifi-start" <<'PY'
import os
import pathlib
import re
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as work:
    root = pathlib.Path(work)
    def write(path, value):
        p = root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(value)
        return p
    host = root / 'sys/devices/platform/ACPI0000/80860F14:00'
    card = host / 'mmc_host/mmc1/mmc1:0001'
    write(str(card.relative_to(root) / 'type'), 'MMC\n')
    write(str(host.relative_to(root) / 'power/control'), 'auto\n')
    write(str(host.relative_to(root) / 'power/autosuspend_delay_ms'), '50\n')
    # The old two-components algorithm would change this unrelated parent.
    parent_control = write('sys/devices/platform/ACPI0000/power/control', 'auto\n')
    driver = root / 'sys/bus/platform/drivers/sdhci-acpi'
    driver.mkdir(parents=True)
    (host / 'driver').symlink_to(driver)
    blk = root / 'sys/class/block/mmcblk1'
    blk.mkdir(parents=True)
    (blk / 'device').symlink_to(card)
    write('proc/modules', 'i915 100 0 - Live 0\n')
    gov = write('sys/devices/system/cpu/cpu0/cpufreq/scaling_governor', 'performance\n')
    write('sys/devices/system/cpu/cpu0/cpufreq/scaling_driver', 'intel_pstate\n')
    write('sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors', 'performance powersave\n')
    cap = write('sys/devices/system/cpu/intel_pstate/max_perf_pct', '100\n')
    write('etc/default/qm1-hardware', 'Qm1_MAX_FREQ_PERC=80\n')
    (root / 'var/log').mkdir(parents=True)
    mock = root / 'bin'
    mock.mkdir()
    for name, body in {
        'logger': 'exit 0',
        'modprobe': 'printf "%s\\n" "$*" >> "$FIXTURE_MODULE_LOG"',
    }.items():
        p = mock / name
        p.write_text('#!/bin/sh\n' + body + '\n')
        p.chmod(0o755)
    env = dict(os.environ, PATH=str(mock) + os.pathsep + os.environ['PATH'],
               FIXTURE_MODULE_LOG=str(root / 'modules.log'))
    # Only filesystem literals change; execute the production control flow.
    text = pathlib.Path(sys.argv[1]).read_text()
    for prefix in ('/sys/', '/proc/', '/etc/', '/var/log/'):
        text = text.replace(prefix, str(root) + prefix)
    script = write('fixups.sh', text)
    subprocess.run(['sh', str(script)], env=env, check=True)
    assert (host / 'power/control').read_text().strip() == 'on'
    assert (host / 'power/autosuspend_delay_ms').read_text().strip() == '-1'
    assert parent_control.read_text().strip() == 'auto', 'changed unrelated ACPI parent'
    assert gov.read_text().strip() == 'powersave'
    assert cap.read_text().strip() == '80', 'frequency cap did not reach max_perf_pct'
    assert 'snd-hdmi-lpe-audio' in (root / 'modules.log').read_text()
    # Generic powersave would lock the minimum frequency; choose schedutil.
    write('sys/devices/system/cpu/cpu0/cpufreq/scaling_driver', 'acpi-cpufreq\n')
    write('sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors', 'performance powersave schedutil\n')
    subprocess.run(['sh', str(script)], env=env, check=True)
    assert gov.read_text().strip() == 'schedutil'
    # SDIO device uevents contain concrete class numbers, not alias wildcards.
    uevent = write('sys/bus/sdio/devices/mmc0:0001:1/uevent', 'MODALIAS=sdio:c00v024CdB723\n')
    wifi = pathlib.Path(sys.argv[2]).read_text()
    func = re.search(r'^sdio_card_present\(\) \{.*?^\}', wifi, re.M | re.S).group()
    func = func.replace('/sys/', str(root) + '/sys/')
    for content, expected in [('MODALIAS=sdio:c00v024CdB723\n', 0),
                              ('MODALIAS=sdio:c07v024CdB723\n', 0),
                              ('MODALIAS=sdio:c00v1234dB723\n', 1)]:
        uevent.write_text(content)
        result = subprocess.run(['sh', '-c', func + '\nsdio_card_present'])
        assert result.returncode == expected, content
print('PASS nested eMMC ownership, parent isolation, PM readback, CPU governors/cap, LPE audio, concrete SDIO IDs')
PY
