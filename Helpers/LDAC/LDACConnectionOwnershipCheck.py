from pathlib import Path
import subprocess
import tempfile

base = Path(__file__).resolve().parents[2]
source = (base / 'Helpers/LDAC/PairedSonyConnectionProbe.m').read_text()
timing = source[source.index('static void RunLoopFor('):source.index('static BOOL ParentInputEnded(')]
normalize = timing[timing.index('static int FreshACLState('):]
observer = source[source.index('@interface ConnectionObserver'):source.index('static int WatchConnection(')]
cancel = source[source.index('        if (cancelled) {'):source.index('        printf("AFTER callback=', source.index('        if (cancelled) {'))]
watch = source[source.index('static int WatchConnection('):source.index('int main(')]
main = source[source.index('int main('):].replace('int main(', 'static int ProbeMain(')
lifetime = (base / 'Helpers/LDAC/LDACParentLifetime.h').read_text()
fixture = r'''
__LIFETIME__
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#include <assert.h>
#include <errno.h>
#include <math.h>
#include <signal.h>
#include <string.h>
#include <sys/event.h>
#include <time.h>
#include <unistd.h>
@class ConnectionObserver;
@interface FixtureDevice : NSObject
@property BOOL paired, connected;
@property BluetoothConnectionHandle connectionHandle;
@property NSUInteger closes, opens;
- (id)classicPeer;
+ (FixtureDevice *)deviceWithAddressString:(NSString *)address;
- (BOOL)isPaired;
- (BOOL)isConnected;
- (IOReturn)closeConnection;
- (IOReturn)openConnection:(ConnectionObserver *)observer;
- (IOBluetoothUserNotification *)registerForDisconnectNotification:(id)observer selector:(SEL)selector;
@end
@interface FixtureNotification : NSObject
- (void)unregister;
@end
@implementation FixtureNotification
- (void)unregister {}
@end
static FixtureDevice *fixtureDevice;
static ConnectionObserver *activeObserver;
static BOOL disarmed;
static int inputChecks;
static int cancelAtCheck = -1;
static double cancelAt = -1;
static double completeAt = 0;
static IOReturn callbackStatus = kIOReturnSuccess;
static IOReturn acquisitionStatus = kIOReturnSuccess;
static void Complete(void);
static int fixtureNative;
static double elapsed;
static double publishAt = -1;
static double disconnectAt = -1;
static void (*tick)(void);
static double MonotonicTime(void) { return elapsed; }
static void RunLoopFor(double seconds) { elapsed += seconds; if (tick) tick(); Complete(); if (disconnectAt >= 0 && elapsed >= disconnectAt) fixtureDevice.connected = NO; }
static int ConnectionLock(NSString *address, BOOL watching) { return 42; }
static BOOL ParentInputEnded(void) { inputChecks++; if ((cancelAtCheck >= 0 && inputChecks >= cancelAtCheck) || (cancelAt >= 0 && elapsed >= cancelAt)) disarmed = YES; return disarmed; }
static BOOL ParentExited(int descriptor) { return NO; }
static int PriorityIdle(NSString *uid) { return 1; }
static int NativeOutputState(NSString *address) { return publishAt >= 0 && elapsed >= publishAt ? 1 : fixtureNative; }
static BOOL FixtureConnected(FixtureDevice *device) { return device.connected; }
@interface FixturePeer : NSObject
- (id)sendInternalSyncMsg:(int)message args:(id)arguments;
@end
@implementation FixturePeer
- (id)sendInternalSyncMsg:(int)message args:(id)arguments {
    assert(message == 0x2f && arguments == nil);
    return @{@"kCBMsgArgState": @{@"kCBMsgArgInternalState": @(fixtureDevice.connected ? 2 : 0)}};
}
@end
#define IOBluetoothDevice FixtureDevice
#define SonyClassicIsConnected FixtureConnected
''' + normalize + observer + r'''
@implementation FixtureDevice
+ (FixtureDevice *)deviceWithAddressString:(NSString *)address { return fixtureDevice; }
- (id)classicPeer { return [FixturePeer new]; }
- (BOOL)isPaired { return self.paired; }
- (BOOL)isConnected { return self.connected; }
- (IOReturn)closeConnection { self.closes++; self.connected = NO; return 0; }
- (IOReturn)openConnection:(ConnectionObserver *)observer { self.opens++; if (acquisitionStatus != kIOReturnSuccess) return acquisitionStatus; self.connected = YES; activeObserver = observer; Complete(); return 0; }
- (IOBluetoothUserNotification *)registerForDisconnectNotification:(id)observer selector:(SEL)selector { return (IOBluetoothUserNotification *)[FixtureNotification new]; }
@end
static void Complete(void) {
    if (activeObserver && !activeObserver.done && completeAt >= 0 && elapsed >= completeAt)
        [activeObserver connectionComplete:fixtureDevice status:callbackStatus];
}
''' + watch + 'static int Cancel(FixtureDevice *device, ConnectionObserver *observer) { BOOL cancelled = YES; int acquisitionFailure = 0;\n' + cancel + '\nreturn 8; }\n' + main + r'''
static int Invoke(NSArray<NSString *> *arguments, BOOL connected, UInt16 handle, int native) {
    fixtureDevice = [FixtureDevice new];
    fixtureDevice.paired = YES;
    fixtureDevice.connected = connected;
    fixtureDevice.connectionHandle = handle;
    fixtureNative = native;
    elapsed = 0;
    inputChecks = 0;
    disarmed = NO;
    activeObserver = nil;
    const char *values[32];
    for (NSUInteger i = 0; i < arguments.count; ++i) values[i] = arguments[i].UTF8String;
    return ProbeMain((int)arguments.count, values);
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        NSArray *connect = @[@"fixture", @"--address", @"02-00-00-00-00-01", @"--watch-parent"];
        cancelAt = 0;
        int early = Invoke(connect, NO, 0, 0);
        assert(early == 0 && fixtureDevice.opens == 0 && fixtureDevice.closes == 0);
        cancelAt = 0.1;
        completeAt = 0.5;
        int settling = Invoke(connect, NO, 0, 0);
        assert(settling == 0 && fixtureDevice.opens == 1 && fixtureDevice.closes == 1);
        callbackStatus = 1;
        int failed = Invoke(connect, NO, 0, 0);
        assert(failed == 5 && fixtureDevice.opens == 1 && fixtureDevice.closes == 0);
        callbackStatus = kIOReturnSuccess;
        cancelAt = -1;
        completeAt = 0;
        acquisitionStatus = 1;
        int rejected = Invoke(connect, NO, 0, 0);
        assert(rejected == 3 && fixtureDevice.opens == 1 && fixtureDevice.closes == 0);
        acquisitionStatus = kIOReturnSuccess;
        cancelAtCheck = 3;
        int after = Invoke(connect, NO, 0, 0);
        assert(after == 0 && fixtureDevice.opens == 1 && fixtureDevice.closes == 0);
        cancelAtCheck = -1;
        activeObserver = nil;
        puts("PASS actual helper cancellation before issuance, pending/failed acquisition including zero, and disarm after completion");
        for (NSNumber *done in @[@NO, @YES]) {
            for (NSNumber *success in @[@NO, @YES]) {
                elapsed = 0;
                FixtureDevice *device = [FixtureDevice new];
                device.connected = YES;
                device.connectionHandle = 0;
                ConnectionObserver *observer = [ConnectionObserver new];
                observer.done = done.boolValue;
                observer.status = success.boolValue ? kIOReturnSuccess : 1;
                observer.originalHandle = 0;
                int canceled = Cancel(device, observer);
                BOOL acquired = done.boolValue && success.boolValue;
                assert(device.closes == (acquired ? 1 : 0) && canceled == (acquired ? 0 : 5));
            }
        }
        elapsed = 0;
        FixtureDevice *replaced = [FixtureDevice new];
        replaced.connected = YES;
        replaced.connectionHandle = 2;
        ConnectionObserver *retired = [ConnectionObserver new];
        retired.done = YES;
        retired.status = kIOReturnSuccess;
        retired.originalHandle = 1;
        assert(Cancel(replaced, retired) == 0 && replaced.closes == 0);
        puts("PASS cancellation before completion, failed acquisition with valid zero, after successful completion and replacement");
        NSArray *restore = @[@"fixture", @"--address", @"02-00-00-00-00-01", @"--restore", @"--disconnect"];
        int status = Invoke(restore, YES, 2, 0);
        assert(status == 6 && fixtureDevice.closes == 0);
        puts("PASS no owned handle: preserves existing ACL");
        NSArray *expected = [restore arrayByAddingObjectsFromArray:@[@"--expected-handle", @"0001"]];
        status = Invoke(expected, YES, 2, 0);
        assert(status == 6 && fixtureDevice.closes == 0);
        puts("PASS replacement handle: preserves existing ACL");
        publishAt = 0.25;
        status = Invoke(expected, YES, 2, 0);
        assert(status == 0 && fixtureDevice.closes == 0 && elapsed >= publishAt);
        puts("PASS replacement before native publication: waits and preserves it");
        publishAt = -1;
        disconnectAt = 0.25;
        status = Invoke(expected, YES, 2, 0);
        assert(status == 0 && fixtureDevice.closes == 0 && fixtureDevice.opens == 0);
        puts("PASS replacement lost while waiting: disconnected without new ordinary-audio acquisition");
        disconnectAt = -1;
        status = Invoke(expected, YES, 1, 0);
        assert(status == 0 && fixtureDevice.closes == 1 && !fixtureDevice.connected);
        puts("PASS matching owned handle: closes exactly once");
        NSArray *zero = [restore arrayByAddingObjectsFromArray:@[@"--expected-handle", @"0000"]];
        status = Invoke(zero, YES, 0, 0);
        assert(status == 0 && fixtureDevice.closes == 1);
        puts("PASS valid zero acquired handle is accepted");
        status = Invoke(expected, NO, 2, 0);
        assert(status == 0 && fixtureDevice.closes == 0);
        puts("PASS disconnected target: no redundant close");
        status = Invoke(expected, YES, 1, -1);
        assert(status == 6 && fixtureDevice.closes == 0);
        puts("PASS native output inspection failure prevents disconnect");
        status = Invoke(expected, YES, 2, 1);
        assert(status == 0 && fixtureDevice.closes == 0);
        puts("PASS published native audio: preserved before handle comparison");
        for (NSString *invalid in @[@"", @"1", @"FFFF", @"+001", @"zzzz", @"10000"] ) {
            status = Invoke([restore arrayByAddingObjectsFromArray:@[@"--expected-handle", invalid]], YES, 1, 0);
            assert(status == 2 && fixtureDevice.closes == 0);
        }
        status = Invoke([expected arrayByAddingObjectsFromArray:@[@"--expected-handle", @"0001"]], YES, 1, 0);
        assert(status == 2 && fixtureDevice.closes == 0);
        status = Invoke(@[@"fixture", @"--address", @"02-00-00-00-00-01", @"--disconnect", @"--expected-handle", @"0001"], YES, 1, 0);
        assert(status == 2 && fixtureDevice.closes == 0);
        puts("PASS malformed, repeated and misplaced expected handles rejected");
        status = Invoke(@[@"fixture", @"--address", @"02-00-00-00-00-01", @"--disconnect"], YES, 2, 0);
        assert(status == 0 && fixtureDevice.closes == 1);
        puts("PASS explicit initial takeover still disconnects the selected target");
    }
    return 0;
}
'''
fixture = fixture.replace('__LIFETIME__', lifetime)
with tempfile.TemporaryDirectory(prefix="acouplet-connection-ownership-") as directory:
    path = Path(directory) / 'ConnectionBoundary.m'
    path.write_text(fixture)
    binary = path.with_suffix('')
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Werror', '-framework', 'Foundation', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Werror', '-fsyntax-only', '-mmacosx-version-min=15.4', str(base / 'Helpers/LDAC/PairedSonyConnectionProbe.m')], check=True)
print('PASS complete connection helper compiles; executed connection/audio boundaries were fixtures')
