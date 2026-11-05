#!/usr/bin/env python3
"""Own one loopback native host, fixture and simulator client; restore the installed host on exit."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[3]
os.chdir(root)
out, client_app, udid = Path(sys.argv[1]).absolute(), Path(sys.argv[2]).absolute(), sys.argv[3]
existing_display = '--existing-display' in sys.argv[4:]
out.mkdir(parents=True, exist_ok=False)
simctl = '/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl'
processes = []
installed_stopped = False
result = {'passed': False}
try:
    rows = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
    for row in rows:
        if row.strip().endswith('/Applications/DUO你电脑 Mac.app/Contents/MacOS/DuoDeskHost'):
            pid = int(row.split(None, 1)[0]); os.kill(pid, signal.SIGTERM); installed_stopped = True
            for _ in range(80):
                try: os.kill(pid, 0)
                except ProcessLookupError: break
                time.sleep(.05)
            else: raise RuntimeError('installed host did not finish restoration')
    fixture = subprocess.Popen([str(root / '.build/native-pipeline/Fixture'), str(out / 'fixture.json')],
                               stdout=(out / 'fixture.log').open('wb'), stderr=subprocess.STDOUT)
    processes.append(fixture)
    for _ in range(100):
        if (out / 'fixture.json').exists(): break
        time.sleep(.05)
    before = json.loads((out / 'fixture.json').read_text())
    host = subprocess.Popen([str(root / '.build/native-pipeline/Host')], env=dict(os.environ, SILL_TEST_LOOPBACK='1'),
                            stdout=(out / 'host.log').open('wb'), stderr=subprocess.STDOUT)
    processes.append(host)
    port = None
    for _ in range(120):
        sockets = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(host.pid), '-iTCP', '-sTCP:LISTEN', '-Fn'],
                                 capture_output=True, text=True)
        match = re.search(r'^n127\.0\.0\.1:(\d+)$', sockets.stdout, re.M)
        if match: port = int(match.group(1)); break
        assert host.poll() is None, (out / 'host.log').read_text()[-3000:]
        time.sleep(.1)
    assert port, 'native host did not bind loopback'
    subprocess.run([simctl, 'install', udid, str(client_app)], check=True)
    data = Path(subprocess.check_output([simctl, 'get_app_container', udid, 'com.duodesk.tests.NativePipeline', 'data'], text=True).strip())
    result_file = data / 'Documents/pipeline-result.json'
    if result_file.exists(): result_file.rename(out / 'previous-client-result.json')
    client_args = [simctl, 'launch', '--console', udid, 'com.duodesk.tests.NativePipeline',
        '-PipelinePort', str(port), '-PipelineFixture', str(out / 'fixture.json'), '-DuoSimulatorSoftwareDecode', 'YES']
    if existing_display:
        client_args += ['-PipelineExistingDisplay', 'YES']
    client = subprocess.Popen(client_args,
        stdout=(out / 'client.log').open('wb'), stderr=subprocess.STDOUT)
    processes.append(client)
    limit = time.monotonic() + 240
    while not result_file.exists() and time.monotonic() < limit:
        assert host.poll() is None, 'host exited during pipeline'
        if client.poll() is not None: break
        time.sleep(.2)
    assert result_file.exists(), (out / 'client.log').read_text(errors='replace')[-4000:]
    result.update(json.loads(result_file.read_text()))
    (out / 'client-result.json').write_text(result_file.read_text())
    assert result['passed'], result.get('error')
    if existing_display:
        log = (out / 'host.log').read_text(errors='replace')
        starts = len(re.findall(r'^Streaming the whole desktop at ', log, re.M))
        assert 3 <= starts <= 5, f'Posture changes or repeated viewports restarted capture unexpectedly: {starts} starts'
        assert 'Duo desktop handoff recorded' not in log, 'existing-display capture attempted a desktop handoff'
        assert result['displayConfigurationUnchanged'], 'physical display configuration changed'
        assert before['displayConfiguration'] == json.loads((out / 'fixture.json').read_text())['displayConfiguration'], \
            'physical display configuration changed during the test'
        result['captureStarts'] = starts
except BaseException as error:
    result['passed'] = False
    result['harnessError'] = str(error)
    raise
finally:
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=8)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
    result['ownedProcessesExited'] = all(p.poll() is not None for p in processes)
    if installed_stopped:
        subprocess.run(['open', '-g', '/Applications/DUO你电脑 Mac.app'], check=True)
    result['installedHostRelaunched'] = installed_stopped
    (out / 'result.json').write_text(json.dumps(result, indent=2))
print('PASS: real screen → hardware host encoder → network → production iOS decoder/presenter → real fixture input')
