from pathlib import Path
import base64
import importlib.util
import io
import json
import os
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
from unittest.mock import patch
import xml.etree.ElementTree as ET

packaging = Path(__file__).parent.resolve()
spec = importlib.util.spec_from_file_location('release', packaging / 'update-feed.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def rejects(operation):
    try:
        operation()
    except (ValueError, RuntimeError):
        return
    raise AssertionError('The release boundary accepted invalid input.')


with tempfile.TemporaryDirectory(prefix='acouplet-update-feed-check-') as directory:
    root = Path(directory).resolve()
    swift = root / 'FixtureSigner.swift'
    swift.write_text('''import CryptoKit
import Foundation
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
if CommandLine.arguments.count == 1 {
    print(key.publicKey.rawRepresentation.base64EncodedString())
} else {
    let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    print(try key.signature(for: bytes).base64EncodedString())
}
''')
    signer = root / 'fixture-signer'
    subprocess.run(['/usr/bin/xcrun', 'swiftc', swift, '-o', signer], check=True)
    public_key = subprocess.check_output([signer], text=True).strip()

    def signature(path):
        return subprocess.check_output([signer, path], text=True).strip()

    updates = root / 'updates'
    updates.mkdir()
    archive = updates / 'Fixture-1.2.3.dmg'
    archive.write_bytes(b'Test archive bytes, not a distributable disk image.')
    notes = updates / 'Fixture-1.2.3.md'
    notes.write_text('Fixture notes.\n')
    original_archive, original_notes = archive.read_bytes(), notes.read_bytes()

    def signed_feed(build=42, url=None, signed_notes=True):
        feed = ET.Element('rss', {'version': '2.0'})
        channel = ET.SubElement(feed, 'channel')
        item = ET.SubElement(channel, 'item')
        ET.SubElement(item, release.NS + 'version').text = str(build)
        ET.SubElement(item, release.NS + 'shortVersionString').text = '1.2.3'
        ET.SubElement(item, 'enclosure', {'url': url or release.github_download_prefix('fixture/repo', '1.2.3') + archive.name,
                                        'length': str(archive.stat().st_size), release.NS + 'edSignature': signature(archive)})
        note_attributes = {release.NS + 'length': str(notes.stat().st_size), release.NS + 'edSignature': signature(notes)} if signed_notes else {}
        ET.SubElement(item, release.NS + 'releaseNotesLink', note_attributes).text = release.PREFIX + notes.name
        path = updates / 'appcast.xml'
        content = ET.tostring(feed, encoding='utf-8', xml_declaration=True) + b'\n'
        path.write_bytes(content)
        block = '<!-- sparkle-signatures:\nedSignature: ' + signature(path) + '\nlength: ' + str(len(content)) + '\n-->\n'
        path.write_bytes(content + block.encode())
        return path.read_bytes()

    original_feed = signed_feed()
    assert release.verify_updates(root, updates, public_key, 42, '1.2.3', repository='fixture/repo') == 42
    for target, original in [(archive, original_archive), (notes, original_notes), (updates / 'appcast.xml', original_feed)]:
        target.write_bytes(original.replace(original[:1], b'!', 1))
        rejects(lambda: release.verify_updates(root, updates, public_key, 42, '1.2.3', repository='fixture/repo'))
        target.write_bytes(original)
    rejects(lambda: release.verify_updates(root, updates, base64.b64encode(bytes(32)).decode(), repository='fixture/repo'))
    rejects(lambda: release.verify_updates(root, updates, public_key, 41, '1.2.3', repository='fixture/repo'))
    rejects(lambda: release.verify_updates(root, updates, public_key, 42, '1.2.4', repository='fixture/repo'))
    for url in ['https://other.example/updates/a.dmg', 'https://baglayan.dev/updates/%2e%2e/a.dmg',
                'https://baglayan.dev/updates/a.dmg?token=x', 'http://baglayan.dev/updates/a.dmg']:
        rejects(lambda: release.update_path(updates, url))
    for url in ['https://github.com/other/repo/releases/download/v1.2.3/' + archive.name,
                'https://github.com/fixture/repo/releases/download/v1.2.4/' + archive.name,
                'https://github.com/fixture/repo/releases/latest/download/' + archive.name,
                'https://github.com/fixture/repo/releases/download/v1.2.3/%2e%2e/' + archive.name]:
        signed_feed(url=url)
        rejects(lambda: release.verify_updates(root, updates, public_key, repository='fixture/repo'))
    signed_feed()
    signed_feed(signed_notes=False)
    try:
        release.verify_updates(root, updates, public_key, repository='fixture/repo')
    except KeyError:
        pass
    else:
        raise AssertionError('Unsigned notes were accepted.')
    (updates / 'appcast.xml').write_bytes(original_feed)
    for suffix in ['dmg', 'md', 'html', 'txt', 'delta', 'xml']:
        extra = updates / ('unreferenced.' + suffix)
        extra.write_text('Unauthenticated history content.')
        rejects(lambda: release.verify_updates(root, updates, public_key, repository='fixture/repo'))
        extra.unlink()
    assert release.verify_updates(root, updates, public_key, repository='fixture/repo') == 42
    print('real Ed25519 verification; feed/archive/notes tampering, wrong keys and downgrade rejection: passed')
    print('unreferenced history archives, notes, deltas and feeds cannot enter the signing directory: passed')

    archived_feed = updates / 'appcast-1.2.3-notes-1.xml'
    archived_feed.write_bytes(original_feed)
    retired_notes = notes
    notes = updates / 'Fixture-1.2.3-notes-2.md'
    notes.write_text('- Updated the fixture interface.\n')
    signed_feed()
    assert release.verify_updates(root, updates, public_key, 42, '1.2.3', repository='fixture/repo') == 42
    for target, original in [(archived_feed, original_feed), (retired_notes, original_notes)]:
        target.write_bytes(original.replace(original[:1], b'!', 1))
        rejects(lambda: release.verify_updates(root, updates, public_key, repository='fixture/repo'))
        target.write_bytes(original)
    archived_feed.unlink()
    rejects(lambda: release.verify_updates(root, updates, public_key, repository='fixture/repo'))
    notes.unlink()
    notes = retired_notes
    (updates / 'appcast.xml').write_bytes(original_feed)
    print('amended notes retain authenticated original notes; archived feed and notes tampering rejected: passed')

    history = root / 'history.tar.gz'
    for member_name, kind in [('../escape.dmg', tarfile.REGTYPE), ('/escape.dmg', tarfile.REGTYPE),
                              ('link.dmg', tarfile.SYMTYPE), ('bad.key', tarfile.REGTYPE)]:
        with tarfile.open(history, 'w:gz') as output:
            member = tarfile.TarInfo(member_name)
            member.type, member.size = kind, 1 if kind == tarfile.REGTYPE else 0
            output.addfile(member, io.BytesIO(b'x') if member.size else None)
        rejects(lambda: release.extract_history(history, updates))
    with tarfile.open(history, 'w:gz') as output:
        for unused in range(2):
            member = tarfile.TarInfo('duplicate.dmg')
            member.size = 1
            output.addfile(member, io.BytesIO(b'x'))
    rejects(lambda: release.extract_history(history, updates))
    print('history path traversal, symlinks, unexpected files and duplicates: passed')

    generated = root / 'native-generator'
    generated.mkdir()
    info = {'CFBundleIdentifier': 'fixture.release', 'CFBundleName': 'Fixture', 'CFBundleExecutable': 'Fixture',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': '42', 'CFBundleShortVersionString': '1.2.3',
            'LSMinimumSystemVersion': '15.4', 'SURequireSignedFeed': True,
            'SUVerifyUpdateBeforeExtraction': True, 'SUSignedFeedFailureExpirationInterval': 0, 'SUPublicEDKey': public_key}
    fixture = root / 'Fixture.app'
    (fixture / 'Contents/MacOS').mkdir(parents=True)
    (fixture / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    shutil.copyfile('/bin/echo', fixture / 'Contents/MacOS/Fixture')
    (fixture / 'Contents/MacOS/Fixture').chmod(0o755)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', fixture], check=True, capture_output=True)
    subprocess.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', fixture, generated / 'Fixture.zip'], check=True)
    (generated / 'Fixture.md').write_text('Test-only native generator notes.\n')
    generator_home = root / 'native-generator-home'
    generator_home.mkdir()
    fixture_key = base64.b64encode(bytes([0x42] * 32)).decode()
    result = subprocess.run([release.SPARKLE / 'generate_appcast', '--ed-key-file', '-', '--download-url-prefix', release.github_download_prefix('fixture/repo', '1.2.3'),
                             '--release-notes-url-prefix', release.PREFIX, '--disable-signing-warning', '--maximum-deltas', '0', generated],
                            input=fixture_key, capture_output=True, text=True, env={**os.environ, 'CFFIXED_USER_HOME': str(generator_home)})
    assert result.returncode == 0, result.stdout + result.stderr
    assert release.verify_updates(root, generated, public_key, 42, '1.2.3', repository='fixture/repo') == 42
    assert (generated / 'Fixture.md').read_text() == 'Test-only native generator notes.\n'
    assert (generator_home / 'Library/Caches/Sparkle_generate_appcast').is_dir()
    second = root / 'native-generator-next'
    second.mkdir()
    shutil.copy2(generated / 'appcast.xml', second / 'appcast.xml')
    old_url = ET.parse(generated / 'appcast.xml').find('./channel/item/enclosure').attrib['url']
    (fixture / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(info, CFBundleVersion='43', CFBundleShortVersionString='1.2.4')))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', fixture], check=True, capture_output=True)
    subprocess.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', fixture, second / 'Fixture-1.2.4.zip'], check=True)
    (second / 'Fixture-1.2.4.md').write_text('Second native generator notes.\n')
    subprocess.run([release.SPARKLE / 'generate_appcast', '--ed-key-file', '-', '--download-url-prefix', release.github_download_prefix('fixture/repo', '1.2.4'),
                    '--release-notes-url-prefix', release.PREFIX, '--full-release-notes-url', release.HISTORY_URL,
                    '--disable-signing-warning', '--maximum-versions', '0', '--maximum-deltas', '0', second],
                   input=fixture_key, capture_output=True, text=True, check=True, env={**os.environ, 'CFFIXED_USER_HOME': str(generator_home)})
    for path in second.iterdir(): shutil.copy2(path, generated / path.name)
    assert release.verify_updates(root, generated, public_key, 43, '1.2.4', repository='fixture/repo') == 43
    urls = {item.findtext(release.NS + 'version'): item.find('enclosure').attrib['url'] for item in ET.parse(generated / 'appcast.xml').findall('./channel/item')}
    assert urls['42'] == old_url
    assert urls['43'] == release.github_download_prefix('fixture/repo', '1.2.4') + 'Fixture-1.2.4.zip'
    latest = next(item for item in ET.parse(generated / 'appcast.xml').findall('./channel/item') if item.findtext(release.NS + 'version') == '43')
    assert latest.findtext(release.NS + 'fullReleaseNotesLink') == release.HISTORY_URL
    assert latest.findtext(release.NS + 'releaseNotesLink') == release.PREFIX + 'Fixture-1.2.4.md'
    print('official generator preserves older GitHub release URLs when generating only the new archive: passed')
    checksums = root / 'native-SHA256SUMS'
    checksums.write_text('Fixture checksum list.\n')
    signature_output = subprocess.run([release.SPARKLE / 'sign_update', '--ed-key-file', '-', '-p', checksums],
                                      input=fixture_key, capture_output=True, text=True, check=True).stdout.strip()
    release.verify_file(root, public_key, checksums, signature_output, checksums.stat().st_size)
    print('official Sparkle 2.10.0 generator and checksum signing output verified against fixture public key: passed')

    fixture_repo = root / 'feed-repo'
    app = fixture_repo / '.build/package/Acouplet/Acouplet.app'
    (app / 'Contents').mkdir(parents=True)
    (fixture_repo / 'Packaging').mkdir()
    shutil.copy2(packaging / 'VerifySparkleSignature.swift', fixture_repo / 'Packaging/VerifySparkleSignature.swift')
    (fixture_repo / 'dist').mkdir()
    real_run = release.run
    first_history = None
    generator_calls = []

    def feed_command(arguments, input=None, capture=False):
        words = list(map(str, arguments))
        if Path(words[0]).name == 'sign_update':
            assert input is None and '--ed-key-file' not in words
            assert words[words.index('--account') + 1] == 'fixture-account'
            return signature(Path(words[-1]))
        if Path(words[0]).name == 'generate_appcast':
            generator_calls.append(words)
            assert input is None and '--ed-key-file' not in words
            assert words[words.index('--account') + 1] == 'fixture-account'
            assert words[words.index('--maximum-versions') + 1] == '0'
            assert words[words.index('--full-release-notes-url') + 1] == release.HISTORY_URL
            assert '--disable-signing-warning' in words
            folder = Path(words[-1])
            rss = ET.parse(folder / 'appcast.xml').getroot() if (folder / 'appcast.xml').exists() else ET.Element('rss', {'version': '2.0'})
            channel = rss.find('channel')
            if channel is None: channel = ET.SubElement(rss, 'channel')
            assert len(list(folder.glob('*.dmg'))) == 1
            for path in sorted(folder.glob('*.dmg')):
                version = path.stem.removeprefix('Acouplet-')
                item = ET.SubElement(channel, 'item')
                ET.SubElement(item, release.NS + 'version').text = '42' if version == '1.2.3' else '43'
                ET.SubElement(item, release.NS + 'shortVersionString').text = version
                ET.SubElement(item, 'enclosure', {'url': words[words.index('--download-url-prefix') + 1] + path.name, 'length': str(path.stat().st_size),
                                                release.NS + 'edSignature': signature(path)})
                note = path.with_suffix('.md')
                ET.SubElement(item, release.NS + 'releaseNotesLink', {release.NS + 'length': str(note.stat().st_size),
                              release.NS + 'edSignature': signature(note)}).text = release.PREFIX + note.name
            path = folder / 'appcast.xml'
            data = ET.tostring(rss, encoding='utf-8') + b'\n'
            path.write_bytes(data)
            path.write_bytes(data + ('<!-- sparkle-signatures:\nedSignature: ' + signature(path) + '\nlength: ' + str(len(data)) + '\n-->\n').encode())
            return ''
        return real_run(arguments, input=input, capture=capture)

    for version, build in [('1.2.3', 42), ('1.2.4', 43)]:
        phase = root / ('feed-' + str(build))
        phase.mkdir()
        metadata = dict(version=version, build=build, initializeFeed=first_history is None,
                        sdkVersion='27.2', architecture='arm64', githubRepository='fixture/repo',
                        sdk='/private/fixture-sdk')
        (phase / 'release.json').write_text(json.dumps(metadata))
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(info, CFBundleVersion=str(build), CFBundleShortVersionString=version)))
        (fixture_repo / 'dist' / ('Acouplet-' + version + '.dmg')).write_bytes(b'Fixture notarized image')
        with patch.object(release, 'REPO', fixture_repo), patch.object(release, 'run', feed_command):
            release.feed(phase, app=app, archive=fixture_repo / 'dist' / ('Acouplet-' + version + '.dmg'),
                         notes='Fixture release notes.', history=first_history, account='fixture-account')
        assert release.verify_updates(phase, phase / 'publish/updates', public_key, build, version, repository='fixture/repo') == build
        assert (phase / 'publish/website-updates.tar.gz').is_file()
        checksums = phase / 'publish/SHA256SUMS'
        release.verify_file(phase, public_key, checksums, (phase / 'publish/SHA256SUMS.ed25519').read_text().strip(), checksums.stat().st_size)
        with tarfile.open(phase / 'publish/website-updates.tar.gz') as website:
            assert {'SHA256SUMS', 'SHA256SUMS.ed25519'}.issubset(website.getnames())
            assert not any(Path(name).suffix in ['.dmg', '.delta'] for name in website.getnames())
        published_metadata = json.loads((phase / 'publish/release.json').read_text())
        assert set(published_metadata) == set(release.PUBLIC_METADATA)
        assert '/private/' not in (phase / 'publish/release.json').read_text()
        first_history = phase / 'publish/update-history.tar.gz'
    assert len(ET.parse(root / 'feed-43/publish/updates/appcast.xml').findall('./channel/item')) == 2
    phase = root / 'feed-downgrade'
    phase.mkdir()
    (phase / 'release.json').write_text(json.dumps({'version': '1.2.4', 'build': 43, 'githubRepository': 'fixture/repo'}))
    with patch.object(release, 'REPO', fixture_repo), patch.object(release, 'run', feed_command):
        rejects(lambda: release.feed(phase, app=app, archive=archive, notes='Fixture notes.', history=first_history, account='fixture-account'))
    print('feed preparation retains authenticated history, verifies staged artifacts and refuses reused builds: passed')
    saved_history = first_history
    for suffix in ['html', 'md', 'dmg']:
        tampered = root / ('tampered-' + suffix)
        tampered.mkdir()
        release.extract_history(saved_history, tampered)
        (tampered / ('Acouplet-1.2.5.' + suffix)).write_text('Unauthenticated next-release content.')
        first_history = root / ('tampered-' + suffix + '.tar.gz')
        with tarfile.open(first_history, 'w:gz') as history:
            for path in tampered.iterdir(): history.add(path, arcname=path.name, recursive=False)
        phase = root / ('feed-extra-' + suffix)
        phase.mkdir()
        (phase / 'release.json').write_text(json.dumps({'version': '1.2.5', 'build': 44, 'githubRepository': 'fixture/repo'}))
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(info, CFBundleVersion='44', CFBundleShortVersionString='1.2.5')))
        previous_calls = len(generator_calls)
        with patch.object(release, 'REPO', fixture_repo), patch.object(release, 'run', feed_command):
            rejects(lambda: release.feed(phase, app=app, archive=archive, notes='Fixture notes.', history=first_history, account='fixture-account'))
        assert len(generator_calls) == previous_calls
    first_history = saved_history
    phase = root / 'feed-filename-collision'
    phase.mkdir()
    (phase / 'release.json').write_text(json.dumps({'version': '1.2.4', 'build': 44, 'githubRepository': 'fixture/repo'}))
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(info, CFBundleVersion='44', CFBundleShortVersionString='1.2.4')))
    previous_calls = len(generator_calls)
    with patch.object(release, 'REPO', fixture_repo), patch.object(release, 'run', feed_command):
        rejects(lambda: release.feed(phase, app=app, archive=archive, notes='Fixture notes.', history=first_history, account='fixture-account'))
    assert len(generator_calls) == previous_calls
    print('tampered history and immutable filename collisions are refused before signing: passed')
    print('public release metadata omits private SDK paths: passed')
