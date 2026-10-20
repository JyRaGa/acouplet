from pathlib import Path
import json, os, plistlib, subprocess, sys, tempfile

repo = Path(__file__).resolve().parent.parent
python_checks = (
    'Packaging/check-localizations-check.py',
    'Packaging/check-no-sony-artwork.py',
    'Packaging/check-sparkle.py',
    'Packaging/check-update-feed.py',
    'Packaging/check-prepare-updates.py',
    'Packaging/check-release-source.py',
    'Packaging/check-ldac-packing.py',
    'Packaging/check-ldac-build.py',
    'Packaging/check-ldac-output-installer.py',
    'Packaging/check-notarize-ldac-installer.py',
    'Packaging/check-package.py',
    'Packaging/check-install.py',
    'Packaging/check-direct.py',
    'Packaging/check-app-store.py',
    'Packaging/check-preference-panes.py',
    'Helpers/SonyBLEWriteCheck.py',
    'Helpers/LDAC/LDACControllerCleanupCheck.py',
    'Helpers/LDAC/LDACControllerVolumeCheck.py',
    'Helpers/LDAC/LDACNativeOutputRestoreCheck.py',
    'Helpers/LDAC/LDACSessionClosureCheck.py',
    'Helpers/LDAC/LDACCaptureStartupCheck.py',
    'Helpers/LDAC/LDACConnectionOwnershipCheck.py',
    'Helpers/LDAC/LDACLogFreeConnectionCheck.py',
    'Helpers/LDAC/LDACOwnerLifecycleCheck.py',
    'Helpers/LDAC/LDACOwnerExitCheck.py',
    'Packaging/check-all-check.py',
)


def run(*arguments):
    command = list(map(str, arguments))
    print('\nChecking: ' + ' '.join(command), flush=True)
    subprocess.run(command, cwd=repo, check=True, env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})


def main():
    sparkle = repo / '.build/Sparkle-2.10.0'
    required = ('Sparkle.framework/Resources/Info.plist', 'bin/generate_appcast', 'bin/sign_update', 'LICENSE')
    if any(not (sparkle / name).is_file() for name in required):
        raise ValueError('Fetch the test dependency first: Packaging/fetch-sparkle.sh')
    if plistlib.loads((sparkle / required[0]).read_bytes())['CFBundleShortVersionString'] != '2.10.0':
        raise ValueError('The cached Sparkle version must be 2.10.0.')
    derived = repo / '.build/check-all'
    results = derived / 'Results'
    results.mkdir(parents=True, exist_ok=True)
    result = Path(tempfile.mkdtemp(prefix='run-', dir=results)) / 'Acouplet.xcresult'
    run('/usr/bin/xcrun', 'xcodebuild', '-project', repo / 'Acouplet.xcodeproj', '-scheme', 'Acouplet',
        '-configuration', 'Debug', '-destination', 'platform=macOS', '-derivedDataPath', derived,
        '-resultBundlePath', result,
        '-parallel-testing-enabled', 'NO', '-only-testing:AcoupletTests',
        'ACOUPLET_PUBLIC_APIS_ONLY=NO', 'ACOUPLET_NO_SONY_ARTWORK=YES', 'ACOUPLET_SONY_ARTWORK_DIR=',
        'ACOUPLET_DISTRIBUTION=development', 'ENABLE_DEBUG_DYLIB=NO', 'CODE_SIGN_IDENTITY=-', 'CODE_SIGN_STYLE=Manual', 'DEVELOPMENT_TEAM=', 'clean', 'test')
    summary = json.loads(subprocess.check_output(['/usr/bin/xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)], cwd=repo))
    if summary['passedTests'] <= 0 or summary['failedTests'] != 0:
        raise ValueError('XCTest must execute passing tests with no failures. Results: ' + str(result))
    app = derived / 'Build/Products/Debug/Acouplet.app'
    extraction = list((derived / 'Build/Intermediates.noindex/Acouplet.build/Debug/Acouplet.build/Objects-normal').glob('*/Acouplet.SwiftFileList'))
    if not extraction:
        raise ValueError('The test build did not produce the app compiler extraction files.')
    for file_list in extraction:
        run(sys.executable, repo / 'Packaging/check-localizations.py', app, file_list.parent)
    run(sys.executable, repo / 'Packaging/check-sparkle-bundle.py', app)
    run(sys.executable, repo / 'Helpers/check-helper.py', app / 'Contents/Helpers/Acouplet Battery Publisher')
    run(sys.executable, repo / 'Packaging/check-ldac-cli.py', app)
    for path in python_checks:
        arguments = ['--check-mutations'] if path == 'Helpers/LDAC/LDACControllerVolumeCheck.py' else []
        run(sys.executable, repo / path, *arguments)
    run('/bin/sh', repo / 'Packaging/check-virtual-output.sh')
    run('/bin/sh', repo / 'Helpers/NativeBatterySelfTestCheck.sh')
    with tempfile.TemporaryDirectory(prefix='acouplet-standalone-checks-') as directory:
        for source, check in (
            ('Helpers/NativeHUD/BannerLifetime.swift', 'Helpers/NativeHUD/BannerLifetimeCheck.swift'),
            ('Sources/LDACNativeSession.swift', 'Helpers/LDAC/LDACSessionDiagnosticsCheck.swift'),
        ):
            binary = Path(directory) / Path(check).stem
            run('/usr/bin/xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', repo / source, repo / check, '-o', binary)
            run(binary)
        encoder = repo / 'Vendor/libldac'
        for check, arguments in (
            ('Helpers/LDAC/LDACLogFreeSignalingTests.m', []),
            ('Helpers/LDAC/LDACLogFreeMediaTests.m', ['-I', encoder / 'inc', '-I', encoder / 'src',
                                                  encoder / 'src/ldacBT.c', encoder / 'src/ldaclib.c']),
        ):
            binary = Path(directory) / Path(check).stem
            run('/usr/bin/xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Werror', '-D_DARWIN_C_SOURCE',
                '-DACOUPLET_LDAC_PROBE_ONLY=0', '-mmacosx-version-min=15.4',
                '-framework', 'Foundation', '-framework', 'CoreFoundation', '-framework', 'CoreBluetooth',
                '-framework', 'IOBluetooth', repo / check, *arguments, '-o', binary)
            run(binary)
    print('\nAll local checks passed.', flush=True)


if __name__ == '__main__':
    if len(sys.argv) != 1:
        sys.exit('Usage: python3 Packaging/check-all.py')
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
