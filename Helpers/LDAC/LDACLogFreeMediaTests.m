#define main LogFreeMediaMain
#include "DirectAVDTPLiveMediaProbe.m"
#undef main

@interface TestMediaChannel : NSObject
@property UInt16 PSM;
@property UInt16 cid;
@property UInt16 outgoingMTU;
@end
@implementation TestMediaChannel
@end

@interface TestMediaManager : NSObject
@property(strong) id peer;
- (id)peerWithIdentifier:(NSUUID *)identifier;
@end
@implementation TestMediaManager
- (id)peerWithIdentifier:(NSUUID *)identifier { return self.peer; }
@end

@interface TestMediaPeer : NSObject
@property(weak) TestMediaManager *manager;
@property(strong) NSUUID *identifier;
@property NSInteger internalState;
@property(strong) id reply;
@property NSUInteger queries;
@property NSUInteger updates;
@property NSUInteger closes;
@property BOOL ignoreUpdate;
@property(copy) void (^onQuery)(void);
@property(copy) void (^onUpdate)(void);
@property(copy) void (^onClose)(void);
- (id)sendInternalSyncMsg:(int)message args:(NSDictionary *)arguments;
- (void)handleGetPeerState:(NSDictionary *)reply;
- (void)closeL2CAPChannel:(UInt16)psm;
@end
@implementation TestMediaPeer
- (id)sendInternalSyncMsg:(int)message args:(NSDictionary *)arguments {
    if (message != 0x2f || arguments) abort();
    self.queries++;
    if (self.onQuery) self.onQuery();
    return self.reply;
}
- (void)handleGetPeerState:(NSDictionary *)reply {
    self.updates++;
    if (!self.ignoreUpdate) self.internalState = [reply[@"kCBMsgArgState"][@"kCBMsgArgInternalState"] integerValue];
    if (self.onUpdate) self.onUpdate();
}
- (void)closeL2CAPChannel:(UInt16)psm {
    if (psm != 0x19) abort();
    self.closes++;
    if (self.onClose) self.onClose();
}
@end

static BOOL Check(BOOL condition, const char *name) {
    printf("LIFECYCLE_CHECK name=%s result=%s\n", name, condition ? "PASS" : "FAIL");
    return condition;
}

static DirectMediaProbe *TestProbe(void) {
    DirectMediaProbe *probe = [DirectMediaProbe new];
    probe.pcmFD = -1;
    probe.controlPending = [NSMutableData data];
    return probe;
}

static CBL2CAPChannel *TestChannel(UInt16 psm, UInt16 cid, UInt16 mtu) {
    TestMediaChannel *channel = [TestMediaChannel new];
    channel.PSM = psm;
    channel.cid = cid;
    channel.outgoingMTU = mtu;
    return (CBL2CAPChannel *)channel;
}

static BOOL RefreshChecks(void) {
    TestMediaManager *manager = [TestMediaManager new];
    TestMediaPeer *peer = [TestMediaPeer new];
    manager.peer = peer;
    peer.manager = manager;
    peer.identifier = [NSUUID UUID];
    peer.reply = @{@"kCBMsgArgState": @{@"kCBMsgArgInternalState": @2}};
    BOOL passed = Check(!RefreshOwnedPeer((CBClassicPeer *)peer, (CBClassicManager *)manager) &&
                        peer.queries == 1 && peer.updates == 1 && peer.internalState == 2, "fresh-query-updates-owned-peer");
    NSArray *invalid = @[@[], @{}, @{@"kCBMsgArgState": @2}, @{@"kCBMsgArgState": @{}},
                         @{@"kCBMsgArgState": @{@"kCBMsgArgInternalState": @"2"}},
                         @{@"kCBMsgArgState": @{@"kCBMsgArgInternalState": @0}}];
    for (id reply in invalid) {
        peer.reply = reply;
        passed &= Check(RefreshOwnedPeer((CBClassicPeer *)peer, (CBClassicManager *)manager) != NULL &&
                        peer.updates == 1, "invalid-or-disconnected-query-rejected");
    }
    peer.reply = @{@"kCBMsgArgState": @{@"kCBMsgArgInternalState": @2}};
    peer.internalState = 0;
    peer.ignoreUpdate = YES;
    passed &= Check(RefreshOwnedPeer((CBClassicPeer *)peer, (CBClassicManager *)manager) != NULL &&
                    peer.internalState == 0, "refresh-update-failure-rejected");
    peer.ignoreUpdate = NO;
    manager.peer = nil;
    NSUInteger queries = peer.queries;
    passed &= Check(RefreshOwnedPeer((CBClassicPeer *)peer, (CBClassicManager *)manager) != NULL &&
                    peer.queries == queries, "foreign-peer-not-queried");
    manager.peer = peer;
    __weak TestMediaManager *weakManager = manager;
    peer.onQuery = ^{ weakManager.peer = nil; };
    NSUInteger updates = peer.updates;
    passed &= Check(RefreshOwnedPeer((CBClassicPeer *)peer, (CBClassicManager *)manager) != NULL &&
                    peer.updates == updates, "owner-loss-during-query-rejected");
    peer.onQuery = nil;
    manager.peer = peer;
    peer.onUpdate = ^{ weakManager.peer = nil; };
    passed &= Check(RefreshOwnedPeer((CBClassicPeer *)peer, (CBClassicManager *)manager) != NULL, "owner-loss-during-update-rejected");
    return passed;
}

static BOOL LifecycleChecks(void) {
    CBL2CAPChannel *channel = TestChannel(0x19, 0x0042, 679);
    DirectMediaProbe *probe = TestProbe();
    RecordOwnedOpen(probe, channel, 0);
    BOOL passed = Check(probe.openDone && probe.channel == channel && probe.realCID == 0x0042 &&
                        !probe.failed && !probe.closed, "valid-open-retained");
    RecordOwnedClose(probe, TestChannel(0x19, 0x0042, 679), 0);
    passed &= Check(!probe.closed && probe.failed, "same-cid-foreign-object-rejected");
    RecordOwnedClose(probe, channel, 0);
    passed &= Check(probe.closed, "exact-owned-close-confirmed");
    RecordOwnedClose(probe, channel, 0);
    passed &= Check(probe.closed, "duplicate-owned-close-idempotent");
    probe = TestProbe();
    RecordOwnedOpen(probe, nil, 0);
    passed &= Check(probe.openDone && probe.failed && !probe.openFailed && !probe.closed, "nil-zero-open-indeterminate");
    TestMediaPeer *peer = [TestMediaPeer new];
    passed &= Check(!CloseOwnedChannel(probe, (CBClassicPeer *)peer, 0.01) && peer.closes == 1 &&
                    !probe.closed, "nil-zero-open-cleanup-unconfirmed");
    probe = TestProbe();
    RecordOwnedOpen(probe, nil, 5);
    peer = [TestMediaPeer new];
    passed &= Check(probe.openFailed && CloseOwnedChannel(probe, (CBClassicPeer *)peer, 0.01) &&
                    peer.closes == 0 && !probe.closed, "explicit-open-failure-terminal");
    probe = TestProbe();
    RecordOwnedOpen(probe, channel, 5);
    peer = [TestMediaPeer new];
    passed &= Check(!probe.openFailed && !CloseOwnedChannel(probe, (CBClassicPeer *)peer, 0.01) &&
                    peer.closes == 1, "non-nil-error-channel-still-needs-close");
    probe = TestProbe();
    RecordOwnedOpen(probe, TestChannel(0x19, 0, 679), 0);
    passed &= Check(probe.failed && !probe.openFailed, "zero-cid-open-rejected");
    probe = TestProbe();
    RecordOwnedOpen(probe, TestChannel(0x19, 0x0042, 13), 0);
    passed &= Check(probe.failed && !probe.openFailed, "undersized-mtu-rejected");
    probe = TestProbe();
    RecordOwnedOpen(probe, TestChannel(0x11, 0x0042, 679), 0);
    passed &= Check(probe.failed && !probe.channel, "foreign-psm-open-rejected");
    probe = TestProbe();
    RecordOwnedOpen(probe, channel, 0);
    RecordOwnedOpen(probe, TestChannel(0x19, 0x0043, 679), 0);
    passed &= Check(probe.failed && probe.channel == channel && probe.realCID == 0x0042, "duplicate-open-preserves-original");
    probe = TestProbe();
    RecordOwnedOpen(probe, channel, 0);
    RecordOwnedClose(probe, nil, 0);
    passed &= Check(probe.failed && !probe.closed, "nil-disconnect-rejected");
    probe = TestProbe();
    RecordOwnedOpen(probe, channel, 0);
    RecordOwnedClose(probe, channel, 7);
    passed &= Check(probe.failed && probe.closed, "owned-disconnect-error-fails-session");
    probe = TestProbe();
    RecordOwnedOpen(probe, channel, 0);
    probe.stdinEnded = YES;
    probe.inputEnded = YES;
    peer = [TestMediaPeer new];
    double began = MonotonicTime();
    passed &= Check(!CloseOwnedChannel(probe, (CBClassicPeer *)peer, 0.02) &&
                    MonotonicTime() - began < 0.2 && !probe.closed, "eof-not-close-proof-bounded");
    probe = TestProbe();
    RecordOwnedOpen(probe, channel, 0);
    peer = [TestMediaPeer new];
    DirectMediaProbe *closingProbe = probe;
    peer.onClose = ^{ dispatch_async(dispatch_get_main_queue(), ^{ RecordOwnedClose(closingProbe, channel, 0); }); };
    passed &= Check(CloseOwnedChannel(probe, (CBClassicPeer *)peer, 0.1) && !probe.failed, "asynchronous-owned-close-confirmed");
    probe = TestProbe();
    peer = [TestMediaPeer new];
    DirectMediaProbe *lateProbe = probe;
    __weak TestMediaPeer *weakPeer = peer;
    peer.onClose = ^{
        if (weakPeer.closes == 1) dispatch_async(dispatch_get_main_queue(), ^{ RecordOwnedOpen(lateProbe, channel, 0); });
        else dispatch_async(dispatch_get_main_queue(), ^{ RecordOwnedClose(lateProbe, channel, 0); });
    };
    passed &= Check(CloseOwnedChannel(probe, (CBClassicPeer *)peer, 0.1) && peer.closes == 2 &&
                    !probe.failed, "late-open-closed-after-pending-cancel");
    return passed;
}

static BOOL RejectDaemonCloseCheck(void) {
    int controls[2];
    if (pipe(controls) != 0) return NO;
    int savedInput = dup(STDIN_FILENO);
    if (savedInput < 0 || dup2(controls[0], STDIN_FILENO) < 0) {
        if (savedInput >= 0) close(savedInput);
        close(controls[0]); close(controls[1]);
        return NO;
    }
    BOOL passed = write(controls[1], "transport-closed\n", 17) == 17;
    DirectMediaProbe *probe = TestProbe();
    RecordOwnedOpen(probe, TestChannel(0x19, 0x0042, 679), 0);
    TestMediaPeer *peer = [TestMediaPeer new];
    passed &= !CloseOwnedChannel(probe, (CBClassicPeer *)peer, 0.01) && !probe.closed && probe.failed;
    passed &= dup2(savedInput, STDIN_FILENO) >= 0;
    close(savedInput); close(controls[0]); close(controls[1]);
    return Check(passed, "daemon-close-command-rejected");
}

int main(void) {
    @autoreleasepool {
        BOOL refresh = RefreshChecks();
        BOOL lifecycle = LifecycleChecks();
        BOOL daemon = RejectDaemonCloseCheck();
        BOOL passed = refresh && lifecycle && daemon;
        printf("MEDIA_LIFECYCLE_TESTS result=%s hardwareAccess=0\n", passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
