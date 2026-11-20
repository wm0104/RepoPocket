"""Darwin URLSession transport evidence; no URLProtocol or synthetic delegate calls.

Run: python3 -m unittest discover -s Tests -p test_download_transport.py -v
Optional compiled iOS simulator run: DOWNLOAD_TRANSPORT_SIMULATOR=<booted-UDID>
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
CHUNK = bytes(range(256)) * 128
BODY = CHUNK * 12  # 384 KiB, paced over 2.75 seconds, not a real artifact.
SHORT = bytes(range(256)) * 4


def harness_source():
    source = (ROOT / 'RepoPocket/ReleaseAssetDownload.swift').read_text()
    source = 'struct ReleaseDownloadProgress' + source.split('struct ReleaseDownloadProgress', 1)[1]

    def replace(old, new):
        nonlocal source
        if source.count(old) != 1:
            raise AssertionError('Production instrumentation anchor changed: ' + old)
        source = source.replace(old, new, 1)

    # Observation only: retain the production throttle, lock, actor task and stop
    # guard. Session-level completion hooks own the control's temporary file.
    replace('    let update: (ReleaseDownloadProgress) -> Void',
            '    let trace: Trace\n'
            '    var fixtureFinish: ((URL, URLResponse?) -> Void)?\n'
            '    var fixtureComplete: ((Error?) -> Void)?\n'
            '    var fixtureTask: URLSessionDownloadTask? { lock.lock(); defer { lock.unlock() }; return downloadTask }\n'
            '    let update: (ReleaseDownloadProgress) -> Void')
    replace('init(update:', 'init(trace: Trace, update:')
    replace('policy: URLSessionTaskDelegate = ReleaseAssetRedirectPolicy()',
            'policy: URLSessionTaskDelegate')
    replace('        self.update = update;', '        self.trace = trace; self.update = update;')
    replace('didFinishDownloadingTo location: URL) {',
            'didFinishDownloadingTo location: URL) {\n        fixtureFinish?(location, downloadTask.response)')
    replace('        finish(error: error)',
            '        fixtureComplete?(error)\n        finish(error: error)')
    replace('                    continuation.resume(throwing: CancellationError())',
            '                    trace.add("continuation-resume")\n'
            '                    continuation.resume(throwing: CancellationError())')
    replace('            try FileManager.default.moveItem(at: location, to: file)',
            '            try FileManager.default.moveItem(at: location, to: file)\n'
            '            trace.add("file-preserved")\n            trace.onPreserved?()')
    replace('        continuation.resume(with: result)',
            '        trace.add("continuation-resume")\n        continuation.resume(with: result)')
    replace('        receive(ReleaseDownloadProgress(received: totalBytesWritten, total: totalBytesExpectedToWrite))',
            '        trace.add("didWrite", totalBytesWritten, totalBytesExpectedToWrite)\n'
            '        receive(ReleaseDownloadProgress(received: totalBytesWritten, total: totalBytesExpectedToWrite))')
    replace('        if emit, active {',
            '        if emit { trace.add("eligible", value.received, value.total) }\n'
            '        if emit, active {')
    replace('                Task { @MainActor [weak self] in',
            '                trace.add("enqueued", value.received, value.total)\n'
            '                Task { @MainActor [weak self] in')
    replace('                    guard let self, self.active else { return }',
            '                    guard let self else { return }\n'
            '                    self.trace.add("actor-entered", value.received, value.total)\n'
            '                    guard self.active else {\n'
            '                        self.trace.add("dropped-after-stop", value.received, value.total); return\n'
            '                    }')
    fixture = (ROOT / 'Tests/Fixtures/DownloadTransportHarness.swift').read_text()
    return fixture.replace('// PRODUCTION_PROGRESS', source)


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        self.requests = []
        self.records_lock = threading.Lock()
        super().__init__(('127.0.0.1', 0), FixtureHandler)


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        with self.server.records_lock:
            self.server.requests.append(self.path)
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/known')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path not in ('/known', '/unknown', '/short', '/abort'):
            self.send_error(404)
            return
        body = SHORT if self.path == '/short' else BODY
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Connection', 'close')
        if self.path != '/unknown':
            self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            for start in range(0, len(body), len(CHUNK)):
                self.wfile.write(body[start:start + len(CHUNK)])
                self.wfile.flush()
                if self.path == '/abort':
                    break  # Advertised Content-Length is deliberately not fulfilled.
                if start + len(CHUNK) < len(body):
                    time.sleep(0.25)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True


class DownloadTransportTests(unittest.TestCase):
    def test_source_extraction(self):
        source = harness_source()
        self.assertNotIn('protocol ReleaseAssetDownloading', source)
        self.assertNotIn('// PRODUCTION_PROGRESS', source)
        self.assertIn('session.download(for: URLRequest(url: url), delegate: transfer)', source)
        self.assertIn('session.downloadTask(with: URLRequest(url: url))', source)
        self.assertIn('task.delegate = transfer', source)
        self.assertIn('try await transfer.download(using: session, request: URLRequest(url: url))', source)
        github = (ROOT / 'RepoPocket/GitHub.swift').read_text()
        for start, end in [('    private func download(', '    // These bounded endpoints'),
                           ('    private func downloadBlob(', '    func commitWorkspace')]:
            method = github.split(start, 1)[1].split(end, 1)[0]
            self.assertIn('transfer.download(using: session, request: request)', method)
            self.assertNotIn('session.download(for:', method)
            self.assertIn('defer { transfer.stop() }', method)
        bridge = source.split('func download(using session: URLSession', 1)[1].split('    func cancel()', 1)[0]
        self.assertIn('session.downloadTask(with: request)', bridge)
        self.assertIn('task.delegate = self', bridge)
        self.assertIn('onCancel: { self.cancel() }', bridge)
        self.assertNotIn('URLSession(configuration:', bridge)

    @unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('swiftc'),
                         'Requires macOS swiftc and Darwin Foundation (not Linux FoundationNetworking)')
    def test_real_urlsession_transport(self):
        server = FixtureServer()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix='download-transport-') as folder:
                path = Path(folder) / 'main.swift'
                path.write_text(harness_source())
                binary = Path(folder) / 'transport'
                args = ['swiftc', '-swift-version', '5', '-parse-as-library', str(path), '-o', str(binary)]
                subprocess.run(args, check=True, timeout=120)
                base = 'http://127.0.0.1:' + str(server.server_port)
                commands = [('macOS', [str(binary), base])]
                udid = os.environ.get('DOWNLOAD_TRANSPORT_SIMULATOR')
                if udid:
                    sdk = subprocess.check_output(
                        ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
                    sim_binary = Path(folder) / 'transport-sim'
                    target = platform.machine() + '-apple-ios17.0-simulator'
                    subprocess.run(args[:-2] + ['-sdk', sdk, '-target', target,
                                               '-o', str(sim_binary)], check=True, timeout=120)
                    subprocess.run(['codesign', '--force', '--sign', '-', str(sim_binary)], check=True)
                    commands.append(('iOS simulator', ['xcrun', 'simctl', 'spawn', udid, str(sim_binary), base]))
                failures = []
                for runtime, command in commands:
                    completed = subprocess.run(command, text=True, capture_output=True, timeout=180)
                    # Print everything before assertions; progress regressions must not
                    # abort the executable and erase other cases' transport evidence.
                    print('\nTRANSPORT ' + runtime + '\n' + completed.stdout, flush=True)
                    if completed.stderr:
                        print(completed.stderr, flush=True)
                    self.assertEqual(completed.returncode, 0, runtime)
                    reports = [json.loads(line) for line in completed.stdout.splitlines() if line.startswith('{')]
                    self.assertEqual(len(reports), 27, runtime)
                    for report in reports:
                        failures.extend(self.check_report(runtime, report))
                print('HTTP fixture requests: ' + json.dumps(server.requests), flush=True)
                self.assertIn('/redirect', server.requests)
                self.assertFalse(failures, '\n' + '\n'.join(failures))
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def check_report(self, runtime, report):
        events = report['events']
        path = report['path']
        failures = []
        prefix = runtime + '/' + report['mode'] + '/' + path

        def require(condition, message):
            if not condition:
                failures.append(prefix + ': ' + message)

        def of(kind):
            return [event for event in events if event['kind'] == kind]

        require([e['received'] for e in of('owned-files-left')] == [0], 'bridge temporary file leaked')
        if report['mode'] == 'production':
            require(len(of('continuation-resume')) == 1, 'production continuation must resume exactly once')
        if path.startswith('pause-'):
            counts = [e['received'] for e in of('paused-bytes')]
            require([e['received'] for e in of('suspended')] == [1], 'native task was not suspended')
            require(len(counts) == 2 and 0 < counts[0] == counts[1] < len(BODY), 'native received bytes did not freeze mid-file')
            start = of('paused')[0]['time']
            end = of('resume')[0]['time'] if of('resume') else float('inf')
            require(not any(start <= e['time'] < end for e in of('delivered')), 'progress changed while paused')
            if path == 'pause-resume':
                require([e['received'] for e in of('same-task')] == [1], 'resume replaced native task')
                require(any(e['time'] >= end and e['received'] > counts[0] for e in of('delivered')), 'no new bytes after resume')
        if path in ('cancel', 'pre-cancel', 'pause-cancel', 'session-invalidated', 'abort', 'cancel-after-preserve'):
            require(not of('completed'), 'cancelled/failed download succeeded')
            require(any(e['kind'].startswith('error:') for e in events), 'missing failure')
            if path != 'abort':
                require(bool(of('cancelled')), 'missing cancellation error')
            if path in ('cancel', 'session-invalidated'):
                require(bool(of('didWrite')), 'cancellation probe never observed real transfer')
            if path == 'cancel-after-preserve':
                require(bool(of('file-preserved')), 'cancellation did not reach real file-preservation boundary')
            if path == 'pre-cancel':
                require(not of('didWrite'), 'pre-cancelled task started transferring')
            return failures

        body = SHORT if path.startswith('short') else BODY
        require(not any(e['kind'].startswith('error:') for e in events), 'download failed')
        require(bool(of('completed')), 'no completion')
        require([e['received'] for e in of('size')] == [len(body)], 'incorrect file size')
        require(bool(of('sha256:' + hashlib.sha256(body).hexdigest())), 'incorrect SHA256')
        require([e['received'] for e in of('status')] == [200], 'incorrect response status')
        require(bool(of('redirect')) == (path == 'redirect'), 'unexpected redirect callbacks')
        require(all(e['mainThread'] for e in of('delivered')), 'update not on main thread/MainActor')
        before = of('completed')[0]['time'] if of('completed') else 0
        delivered = [e for e in of('delivered') if e['time'] < before]
        previous = 0
        increasing = 0
        for event in delivered:
            if event['received'] > previous:
                increasing += 1
                previous = event['received']
        print(prefix + ': ' + json.dumps({
            'didWrite': len(of('didWrite')), 'eligible': len(of('eligible')),
            'enqueued': len(of('enqueued')), 'delivered': len(of('delivered')),
            'increasingBeforeCompletion': increasing, 'droppedAfterStop': len(of('dropped-after-stop')),
        }, sort_keys=True), flush=True)
        if not path.startswith('short') and report['mode'] != 'async-per-task':
            require(len(of('didWrite')) >= 2, 'fewer than two native didWrite callbacks')
            require(increasing >= 2, 'fewer than two increasing delivered updates BEFORE completion')
            if path == 'unknown':
                require(bool(delivered) and all(e['total'] is None for e in delivered),
                        'unknown total must retain received bytes with nil total')
            else:
                require(bool(delivered) and all(e['total'] == len(body) for e in delivered),
                        'known total differs from Content-Length')
        if path == 'short-blocked':
            require(not of('actor-timeout'), 'MainActor blocking probe timed out')
            # Evidence only: missing per-task callbacks remain visible in JSON;
            # the control must expose the actual queued-stop boundary.
            if report['mode'] in ('session-download-task', 'production'):
                require(bool(of('enqueued')), 'control did not enqueue real progress')
                require(bool(of('dropped-after-stop')), 'control did not observe stop swallowing queued update')
                require(not of('delivered'), 'blocked progress unexpectedly delivered before stop')
        return failures


if __name__ == '__main__':
    unittest.main()
