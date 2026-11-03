#!/usr/bin/env python3
"""Exercise production source switching on an isolated, loopback-only synthetic host."""
import json
import os
import pathlib
import re
import socket
import struct
import subprocess
import sys
import time

binary, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
output.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, SILL_TEST_LOOPBACK='1', SILL_TEST_INPUT_LOG='1')
log_path = output / 'synthetic-host.log'
process = subprocess.Popen([str(binary), '--synthetic', '--no-clipboard'], env=env,
                           stdout=log_path.open('wb'), stderr=subprocess.STDOUT)
sock = None
epochs = []
observed = []
report = {'synthetic': True, 'realInputSent': False, 'screenCaptureAcceptance': False}
try:
    port = None
    end = time.monotonic() + 12
    while time.monotonic() < end:
        text = log_path.read_text(errors='replace')
        match = re.search(r'(?:port |port: |:)(\d{4,5})\b', text)
        if match:
            port = int(match.group(1))
            break
        sockets = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(process.pid),
                                  '-iTCP', '-sTCP:LISTEN', '-Fn'], capture_output=True, text=True, timeout=3)
        match = re.search(r'^n127\.0\.0\.1:(\d+)$', sockets.stdout, re.M)
        if match:
            port = int(match.group(1))
            break
        assert process.poll() is None, text[-2000:]
        time.sleep(.1)
    assert port, 'synthetic host did not announce its port'
    sock = socket.create_connection(('127.0.0.1', port), timeout=3)
    sock.settimeout(3)

    def send(kind, payload):
        data = json.dumps(payload).encode()
        sock.sendall(struct.pack('>BdBI', kind, time.time(), 0, len(data)) + data)

    def exact(count):
        data = bytearray()
        while len(data) < count:
            chunk = sock.recv(count - len(data))
            assert chunk, 'host closed the test connection'
            data.extend(chunk)
        return bytes(data)

    def catalog(target=None, idle=False):
        end = time.monotonic() + 10
        while time.monotonic() < end:
            kind, _, _, length = struct.unpack('>BdBI', exact(14))
            assert length <= 32 << 20
            payload = exact(length)
            if kind == 34:
                epochs.append(int.from_bytes(payload, 'big'))
            if kind != 2:
                continue
            value = json.loads(payload)
            observed.append(value.get('selectedDisplayID'))
            if target is None or (value.get('selectedDisplayID') == target and
                                  (idle or value['active'] == {'desktop': {}})):
                return value
        raise AssertionError('selected desktop was not acknowledged')

    send(23, {'appVersion': '0.1.0', 'protocol': 1, 'device': 'DUO display selection check'})
    first = catalog()
    assert first['active'] == {'none': {}}, 'host streamed before a source was chosen'
    assert first.get('inputDryRun') is True
    displays = first['displays']
    primary = next(item for item in displays if item['isMain'])
    secondary = next(item for item in displays if not item['isMain'])
    report['displays'] = displays
    assert primary['id'] != secondary['id']

    def viewport(display):
        send(9, {'width': 669, 'height': 476, 'fps': 60,
                 'desktopResolution': {'width': 2007, 'height': 1427},
                 'recoverableDesktopFailure': True, 'displayID': display})

    viewport(primary['id'])
    send(6, {'desktop': {}})
    catalog(primary['id'])
    before = epochs[-1]
    viewport(secondary['id'])
    catalog(secondary['id'])
    assert epochs[-1] > before, 'display switch reused the old input/video epoch'
    for display in [primary['id'], secondary['id'], primary['id']]:
        viewport(display)
    final = catalog(primary['id'])
    assert final['active'] == {'desktop': {}}, 'rapid choices left an idle or window stream'
    viewport(0xFFFFFFFF)
    catalog(primary['id'])
    report.update(passed=True, observedSelections=observed, videoEpochs=epochs)
    print('PASS: default main display, explicit secondary, live switch, rapid choices, invalid-ID rejection and fresh video epochs')
finally:
    if sock:
        sock.close()
    process.terminate()
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    report['testHostExited'] = process.poll() is not None
    (output / 'wire-check.json').write_text(json.dumps(report, indent=2))
