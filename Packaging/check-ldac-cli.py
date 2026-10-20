from pathlib import Path
import subprocess
import sys

helpers = Path(sys.argv[1]) / 'Contents/Helpers'
for name, arguments in [
    ('LDACSignaling', []),
    ('LDACSignaling', ['--discover']),
    ('LDACSignaling', ['--discover', '--address', '02-00-00-00-00-01']),
    ('LDACSignaling', ['--discover-disconnected', '--address', '02-00-00-00-00-01']),
    ('LDACSignaling', ['--capabilities-disconnected', 'received.bin', '--address', '02-00-00-00-00-01']),
    ('LDACSignaling', ['--playback-disconnected', 'received.bin', '--address', '02-00-00-00-00-01']),
    ('LDACMediaTransport', ['--media', '--pcm-fd', '3']),
    ('SonyAudioConnection', []),
    ('LDACLogObserver', []),
]:
    result = subprocess.run([str(helpers / name), *arguments], capture_output=True, text=True, timeout=15)
    assert result.returncode == 2, (name, arguments, result.returncode, result.stdout, result.stderr)
    assert 'BEFORE' not in result.stdout, name

for name in ['LDACSignaling', 'LDACMediaTransport']:
    subprocess.run([str(helpers / name), '--self-test'], check=True, timeout=15)

audio = helpers / 'Acouplet Audio.app/Contents/MacOS/AcoupletAudio'
for arguments in [['capture.caf'], ['--sample-composition', 'capture.caf']]:
    result = subprocess.run([str(audio), *arguments], capture_output=True, text=True, timeout=15)
    assert result.returncode == 2 and 'CREATE_TAP' not in result.stdout, (arguments, result.stdout, result.stderr)
for binary, markers in [
    (audio, [b'CREATE_CAF', b'WRITE_CAF', b'CLOSE_CAF', b'NEW_OUTPUT.caf', b'Acouplet Research']),
    (helpers / 'LDACSignaling', [b'--discover', b'--capabilities-disconnected']),
    (helpers / 'LDACMediaTransport', [b'1..60', b'PACING_LIMIT packet=', b'DRAIN packet=']),
]:
    contents = binary.read_bytes()
    for marker in markers:
        assert marker not in contents, (binary.name, marker)
for argument in ['--check-stream-ring', '--check-stream-rates']:
    subprocess.run([str(audio), argument], check=True, timeout=15)

print('LDAC helpers reject missing addresses and probe modes before device access; production artifacts exclude probe paths; offline self-checks passed.')
