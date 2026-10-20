from pathlib import Path
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parent.parent
SPARKLE = REPO / '.build/Sparkle-2.10.0/bin'
PREFIX = 'https://baglayan.dev/updates/'
HISTORY_URL = 'https://baglayan.dev/acouplet/history/'
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
PUBLIC_METADATA = ['version', 'build', 'initializeFeed', 'sdkVersion', 'architecture', 'githubRepository']


def run(arguments, input=None, capture=False):
    result = subprocess.run(list(map(str, arguments)), input=input, capture_output=capture, text=True)
    if result.returncode:
        raise RuntimeError('Release operation failed: ' + Path(arguments[0]).name)
    return result.stdout if capture else None


def extract_history(archive, updates):
    names = set()
    with tarfile.open(archive, 'r:gz') as source:
        for member in source.getmembers():
            name = Path(member.name)
            if not member.isfile() or len(name.parts) != 1 or name.name in names or name.suffix not in ['.xml', '.dmg', '.md', '.html', '.txt', '.delta']:
                raise ValueError('The update-history archive contains an unexpected path or file type.')
            names.add(name.name)
            with source.extractfile(member) as incoming, (updates / name.name).open('wb') as target:
                shutil.copyfileobj(incoming, target)


def verifier(root):
    binary = root / 'verify-sparkle-signature'
    if not binary.exists():
        run(['/usr/bin/xcrun', 'swiftc', '-O', REPO / 'Packaging/VerifySparkleSignature.swift', '-o', binary])
    return binary


def verify_file(root, public_key, path, signature, length):
    if path.is_symlink() or not path.is_file() or path.stat().st_size != int(length):
        raise ValueError('A signed update file is missing or has the wrong length: ' + path.name)
    run([verifier(root), public_key, path, signature], capture=True)


def github_download_prefix(repository, version):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}', repository):
        raise ValueError('Supply the public GitHub release repository as owner/name.')
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', version):
        raise ValueError('The GitHub release tag requires a numeric app version.')
    return 'https://github.com/' + repository + '/releases/download/v' + version + '/'


def update_path(updates, url, prefix=PREFIX):
    parsed = urlsplit(url)
    expected = urlsplit(prefix)
    path = unquote(parsed.path)
    if parsed.scheme != 'https' or parsed.netloc != expected.netloc or parsed.query or parsed.fragment or not path.startswith(expected.path):
        raise ValueError('Unexpected update URL.')
    filename = path.removeprefix(expected.path)
    if not filename or '/' in filename or '\\' in filename or filename in ['.', '..']:
        raise ValueError('Update URLs must identify flat files under the production update directory.')
    return updates / filename


def verified_appcast(root, feed, public_key):
    data = feed.read_bytes()
    signing = re.search(rb'<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\n?\Z', data)
    if signing is None or int(signing[2]) != signing.start():
        raise ValueError('The generated appcast is missing its complete Sparkle signing block.')
    content = root / 'appcast-content.xml'
    content.write_bytes(data[:signing.start()])
    verify_file(root, public_key, content, signing[1].decode(), signing[2])
    return ET.fromstring(data)


def verify_updates(root, updates, public_key, build=None, version=None, *, repository):
    feed = updates / 'appcast.xml'
    verified = {feed}
    document = verified_appcast(root, feed, public_key)
    versions = []
    for item in document.findall('./channel/item'):
        enclosure = item.find('enclosure')
        item_build = item.findtext(NS + 'version')
        if enclosure is None or item_build is None or not re.fullmatch(r'[1-9][0-9]*', item_build):
            raise ValueError('The appcast contains invalid version or enclosure metadata.')
        number = int(item_build)
        versions.append(number)
        item_version = item.findtext(NS + 'shortVersionString', '')
        download_prefix = github_download_prefix(repository, item_version)
        archive = update_path(updates, enclosure.attrib['url'], download_prefix)
        verify_file(root, public_key, archive, enclosure.attrib[NS + 'edSignature'], enclosure.attrib['length'])
        verified.add(archive)
        for delta in item.findall('.//' + NS + 'deltas/enclosure'):
            path = update_path(updates, delta.attrib['url'], download_prefix)
            verify_file(root, public_key, path, delta.attrib[NS + 'edSignature'], delta.attrib['length'])
            verified.add(path)
        notes = item.find(NS + 'releaseNotesLink')
        if notes is None:
            raise ValueError('Every update must include its signed external release notes.')
        path = update_path(updates, notes.text)
        verify_file(root, public_key, path, notes.attrib[NS + 'edSignature'], notes.attrib[NS + 'length'])
        verified.add(path)
        if number == build and item.findtext(NS + 'shortVersionString') != version:
            raise ValueError('Generated release version does not match the requested version.')
    if not versions or len(versions) != len(set(versions)):
        raise ValueError('The appcast contains no updates or repeated build numbers.')
    if build is not None and (build not in versions or max(versions) != build):
        raise ValueError('The new build must be the highest version in the signed feed.')
    for archived_feed in updates.glob('appcast-*.xml'):
        archived_document = verified_appcast(root, archived_feed, public_key)
        verified.add(archived_feed)
        for notes in archived_document.findall('./channel/item/' + NS + 'releaseNotesLink'):
            path = update_path(updates, notes.text)
            verify_file(root, public_key, path, notes.attrib[NS + 'edSignature'], notes.attrib[NS + 'length'])
            verified.add(path)
    if set(updates.iterdir()) != verified:
        raise ValueError('Update files must exactly match the files referenced by the signed feed.')
    return max(versions)


def feed(root, *, app, archive, notes, history, account):
    metadata = json.loads((root / 'release.json').read_text())
    repository = metadata['githubRepository']
    download_prefix = github_download_prefix(repository, metadata['version'])
    updates = root / 'publish/updates'
    updates.mkdir(parents=True)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info['SURequireSignedFeed'] is not True or info['SUVerifyUpdateBeforeExtraction'] is not True or info['SUSignedFeedFailureExpirationInterval'] != 0:
        raise ValueError('The packaged app must retain the strict signed-feed policy.')
    if info['CFBundleVersion'] != str(metadata['build']) or info['CFBundleShortVersionString'] != metadata['version']:
        raise ValueError('The packaged app has unexpected version metadata.')
    public_key = info['SUPublicEDKey']
    if history:
        extract_history(history, updates)
        previous = verify_updates(root, updates, public_key, repository=repository)
        if metadata['build'] <= previous:
            raise ValueError('Release build number must increase beyond the complete signed history.')
    name = 'Acouplet-' + metadata['version']
    if any(path.name.startswith(name + '.') for path in updates.iterdir()):
        raise ValueError('Release archive and note filenames must be new; versioned update URLs are immutable.')
    shutil.copy2(archive, updates / (name + '.dmg'))
    notes = notes.strip() + '\n'
    (updates / (name + '.md')).write_text(notes)
    with tempfile.TemporaryDirectory(prefix='appcast-', dir=root) as directory:
        generated = Path(directory)
        for path in [updates / (name + '.dmg'), updates / (name + '.md'), updates / 'appcast.xml']:
            if path.exists():
                shutil.copy2(path, generated / path.name)
        run([SPARKLE / 'generate_appcast', '--account', account, '--download-url-prefix', download_prefix,
             '--release-notes-url-prefix', PREFIX, '--full-release-notes-url', HISTORY_URL,
             '--disable-signing-warning', '--maximum-versions', '0', '--maximum-deltas', '0', generated], capture=True)
        shutil.copy2(generated / 'appcast.xml', updates / 'appcast.xml')
    verify_updates(root, updates, public_key, metadata['build'], metadata['version'], repository=repository)
    artifact = root / 'publish'
    (artifact / 'release-notes.md').write_text(notes)
    (artifact / 'release.json').write_text(json.dumps({key: metadata[key] for key in PUBLIC_METADATA}, indent=2) + '\n')
    (artifact / 'SHA256SUMS').write_text(''.join(hashlib.sha256(path.read_bytes()).hexdigest() + '  updates/' + path.name + '\n' for path in sorted(updates.iterdir()) if path.is_file()))
    checksums = artifact / 'SHA256SUMS'
    signature = run([SPARKLE / 'sign_update', '--account', account, '-p', checksums], capture=True).strip()
    verify_file(root, public_key, checksums, signature, checksums.stat().st_size)
    (artifact / 'SHA256SUMS.ed25519').write_text(signature + '\n')
    with tarfile.open(artifact / 'update-history.tar.gz', 'w:gz') as history:
        for path in sorted(updates.iterdir()):
            history.add(path, arcname=path.name, recursive=False)
    with tarfile.open(artifact / 'website-updates.tar.gz', 'w:gz') as website:
        for path in sorted(updates.iterdir()):
            if path.suffix in ['.xml', '.md', '.html', '.txt']:
                website.add(path, arcname='updates/' + path.name, recursive=False)
        for name in ['SHA256SUMS', 'SHA256SUMS.ed25519']:
            website.add(artifact / name, arcname=name, recursive=False)
