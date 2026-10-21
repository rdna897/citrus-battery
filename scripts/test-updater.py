#!/usr/bin/env python3
"""Exercise real Sparkle checks, signatures, replacement and relaunch in temp apps.

Requires a macOS GUI session. Uses its own ephemeral signing key and bundle ID;
does not alter the installed app, production signing key or user preferences.
"""
import functools
import http.server
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = ROOT / '.build/artifacts/sparkle/Sparkle'
FRAMEWORK = SPARKLE / 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)


def run(*args, **kwargs):
    result = subprocess.run([str(a) for a in args], capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed:\n{result.stdout.decode()}\n{result.stderr.decode()}')
    return result


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def test():
    with tempfile.TemporaryDirectory(prefix='citrus-updater-test-') as directory:
        work = Path(directory)
        binary = work / 'UpdateTest'
        run('swiftc', '-parse-as-library', ROOT / 'scripts/UpdaterTestDriver.swift',
            '-F', FRAMEWORK.parent, '-framework', 'Sparkle',
            '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks', '-o', binary)
        # The standalone key-generation invocation also needs to find Sparkle.
        key = work / 'test-key'
        run(binary, '--generate-key', key, env={**os.environ, 'DYLD_FRAMEWORK_PATH': str(FRAMEWORK.parent)})
        key.chmod(0o600)
        public_key = key.with_suffix('.pub').read_text()
        identifier = 'org.citrusbattery.UpdateTest.' + uuid.uuid4().hex
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0),
            functools.partial(QuietHandler, directory=directory))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base_url = f'http://127.0.0.1:{server.server_port}'

        def make_app(parent, version):
            app = parent / 'Citrus Battery.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/Frameworks').mkdir()
            shutil.copy2(binary, app / 'Contents/MacOS/UpdateTest')
            run('ditto', FRAMEWORK, app / 'Contents/Frameworks/Sparkle.framework')
            info = dict(CFBundleName='Citrus Battery Update Test', CFBundleIdentifier=identifier,
                CFBundleExecutable='UpdateTest', CFBundlePackageType='APPL',
                CFBundleVersion=version, CFBundleShortVersionString=version,
                LSMinimumSystemVersion='13.0', SUPublicEDKey=public_key,
                SUFeedURL=f'{base_url}/appcast.xml', SURequireSignedFeed=True,
                SUVerifyUpdateBeforeExtraction=True, SUEnableAutomaticChecks=False,
                SUAutomaticallyUpdate=False, NSAppTransportSecurity={'NSAllowsArbitraryLoads': True})
            with (app / 'Contents/Info.plist').open('wb') as file:
                plistlib.dump(info, file)
            run('codesign', '--force', '--sign', '-', app)
            return app

        try:
            payload = work / 'payload'
            payload.mkdir()
            new_app = make_app(payload, '2.0')
            # Put the app at the ZIP root, as public application ZIPs do.
            archive = work / 'update.zip'
            run('ditto', '-c', '-k', '--sequesterRsrc', payload, archive)
            original_archive = archive.read_bytes()
            signature = run(SPARKLE / 'bin/sign_update', '--ed-key-file', key, '-p', archive).stdout.decode().strip()
            for case in ['no-update', 'incompatible-os', 'tampered-feed', 'tampered-archive', 'install']:
                case_dir = work / case
                case_dir.mkdir()
                installed = make_app(case_dir, '1.0')
                archive.write_bytes(original_archive)
                root = ET.Element('rss', version='2.0')
                channel = ET.SubElement(root, 'channel')
                ET.SubElement(channel, 'title').text = 'Update test'
                item = ET.SubElement(channel, 'item')
                ET.SubElement(item, 'title').text = 'Test update'
                ET.SubElement(item, f'{{{NS}}}version').text = '1.0' if case == 'no-update' else '2.0'
                ET.SubElement(item, f'{{{NS}}}minimumSystemVersion').text = '999.0' if case == 'incompatible-os' else '13.0'
                ET.SubElement(item, 'enclosure', url=f'{base_url}/update.zip',
                    length=str(len(original_archive)), type='application/octet-stream',
                    **{f'{{{NS}}}edSignature': signature})
                feed = work / 'appcast.xml'
                ET.ElementTree(root).write(feed, encoding='utf-8', xml_declaration=True)
                run(SPARKLE / 'bin/sign_update', '--ed-key-file', key, feed)
                if case == 'tampered-feed':
                    feed.write_bytes(feed.read_bytes().replace(b'Test update', b'Fake update'))
                elif case == 'tampered-archive':
                    archive.write_bytes(original_archive[:-1] + bytes([original_archive[-1] ^ 1]))
                log = case_dir / 'result.log'
                process = subprocess.Popen(['open', '-n', '-W', str(installed)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    deadline = time.monotonic() + 55
                    while time.monotonic() < deadline:
                        output = log.read_text() if log.exists() else ''
                        if 'RELAUNCHED 2.0' in output or 'NOT_FOUND' in output or 'ERROR' in output:
                            break
                        time.sleep(0.2)
                    else:
                        raise AssertionError(f'{case} timed out: {output}')
                    if case in ['no-update', 'incompatible-os']:
                        assert 'NOT_FOUND 1001' in output, output
                    elif case == 'tampered-feed':
                        assert 'ERROR 1000' in output or 'ERROR 3001' in output, output
                        assert 'DOWNLOADING' not in output, output
                    elif case == 'tampered-archive':
                        assert 'ERROR 4005' in output and 'signature validation before unarchiving failed' in output, output
                        assert 'INSTALLING' not in output, output
                    else:
                        assert 'INSTALLING' in output and 'RELAUNCHED 2.0' in output, output
                        with (installed / 'Contents/Info.plist').open('rb') as file:
                            assert plistlib.load(file)['CFBundleVersion'] == '2.0'
                        run('codesign', '--verify', '--deep', '--strict', installed)
                    if case != 'install':
                        with (installed / 'Contents/Info.plist').open('rb') as file:
                            assert plistlib.load(file)['CFBundleVersion'] == '1.0'
                    print(f'PASS: {case}', flush=True)
                finally:
                    # Only target the ephemeral test bundle, including on timeout.
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        subprocess.run(['osascript', '-e', f'tell application id "{identifier}" to quit'],
                            capture_output=True, timeout=10)
                        process.terminate()
            print('Updater checks, tamper rejection, installation and relaunch passed.', flush=True)
        finally:
            server.shutdown()
            subprocess.run(['defaults', 'delete', identifier], capture_output=True)
            shutil.rmtree(Path.home() / 'Library/Caches' / identifier, ignore_errors=True)


if __name__ == '__main__':
    test()
