#include <stdint.h>
#include <time.h>
static uint64_t TestClock(clockid_t clock);
#define clock_gettime_nsec_np TestClock
#define main LogFreeSignalingMain
#include "DirectAVDTPSustainedPlaybackProbe.m"
#undef main
#undef clock_gettime_nsec_np
#include <pthread.h>

static NSUInteger clockCallsUntilAdvance;
static uint64_t clockOffset;
static uint64_t TestClock(clockid_t clock) {
    if (clockCallsUntilAdvance && --clockCallsUntilAdvance == 0) clockOffset = 100ULL * NSEC_PER_SEC;
    return clock_gettime_nsec_np(clock) + clockOffset;
}

@interface TestInput : NSInputStream
@property NSMutableArray<NSData *> *chunks;
@property BOOL gap;
@property BOOL ended;
@end
@implementation TestInput
- (instancetype)init { if ((self = [super init])) self.chunks = [NSMutableArray array]; return self; }
- (BOOL)hasBytesAvailable {
    if (self.gap) { self.gap = NO; return NO; }
    return self.chunks.count != 0;
}
- (NSInteger)read:(uint8_t *)buffer maxLength:(NSUInteger)length {
    if (!self.chunks.count) return self.ended ? 0 : -1;
    NSData *chunk = self.chunks.firstObject;
    NSUInteger size = MIN(length, chunk.length);
    memcpy(buffer, chunk.bytes, size);
    [self.chunks removeObjectAtIndex:0];
    if (size < chunk.length) [self.chunks insertObject:[chunk subdataWithRange:NSMakeRange(size, chunk.length - size)] atIndex:0];
    self.gap = YES;
    return size;
}
- (NSStreamStatus)streamStatus { return self.ended && !self.chunks.count ? NSStreamStatusAtEnd : NSStreamStatusOpen; }
- (NSError *)streamError { return nil; }
- (void)open {}
- (void)close {}
@end

@interface TestOutput : NSOutputStream
@property NSMutableArray<NSData *> *writes;
@property(copy) void (^onWrite)(NSData *);
@property BOOL shortWrite;
@end
@implementation TestOutput
- (instancetype)init { if ((self = [super init])) self.writes = [NSMutableArray array]; return self; }
- (NSInteger)write:(const uint8_t *)buffer maxLength:(NSUInteger)length {
    NSData *data = [NSData dataWithBytes:buffer length:length];
    [self.writes addObject:data];
    if (self.onWrite) self.onWrite(data);
    return self.shortWrite ? (NSInteger)length - 1 : (NSInteger)length;
}
- (BOOL)hasSpaceAvailable { return YES; }
- (NSStreamStatus)streamStatus { return NSStreamStatusOpen; }
- (NSError *)streamError { return nil; }
- (void)open {}
- (void)close {}
@end

@interface TestChannel : NSObject
@property UInt16 PSM;
@property UInt16 cid;
@property UInt16 outgoingMTU;
@property TestInput *inputStream;
@property TestOutput *outputStream;
@end
@implementation TestChannel
@end

static NSUInteger checks;
static void Check(BOOL condition, const char *name) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL %s check=%lu\n", name, checks); exit(1); }
}
static NSData *Hex(NSString *string) {
    NSMutableData *result = [NSMutableData data];
    for (NSString *part in [string componentsSeparatedByString:@" "]) {
        if (!part.length) continue;
        unsigned value = 0;
        Check(part.length == 2 && [[NSScanner scannerWithString:part] scanHexInt:&value] && value <= 255, "hex fixture");
        uint8_t byte = value;
        [result appendBytes:&byte length:1];
    }
    return result;
}
static void Chunks(TestInput *input, NSData *bytes, NSUInteger split, BOOL bytewise) {
    if (bytewise) {
        for (NSUInteger index = 0; index < bytes.length; index++)
            [input.chunks addObject:[bytes subdataWithRange:NSMakeRange(index, 1)]];
    } else if (split && split < bytes.length) {
        [input.chunks addObject:[bytes subdataWithRange:NSMakeRange(0, split)]];
        [input.chunks addObject:[bytes subdataWithRange:NSMakeRange(split, bytes.length - split)]];
    } else if (bytes.length) [input.chunks addObject:bytes];
}
static DirectPlaybackProbe *Probe(void) {
    DirectPlaybackProbe *probe = [DirectPlaybackProbe new];
    TestChannel *channel = [TestChannel new];
    channel.PSM = 0x19;
    channel.cid = 0x1001;
    channel.outgoingMTU = 679;
    channel.inputStream = [TestInput new];
    channel.outputStream = [TestOutput new];
    probe.channel = (id)channel;
    probe.realCID = channel.cid;
    probe.input = channel.inputStream;
    probe.output = channel.outputStream;
    probe.pending = [NSMutableData data];
    probe.raw = [NSMutableData data];
    probe.controlPending = [NSMutableData data];
    probe.hardDeadline = MonotonicTime() + 2;
    probe.sampleRate = 48000;
    probe.quality = @"low";
    return probe;
}
static int parentWrite;
static int originalInput;
static void ResetParent(void) {
    if (parentWrite >= 0) close(parentWrite);
    int pair[2];
    Check(pipe(pair) == 0, "parent pipe");
    Check(dup2(pair[0], STDIN_FILENO) == STDIN_FILENO, "replace stdin");
    close(pair[0]);
    parentWrite = pair[1];
    interrupted = 0;
}
static void ParentLine(const char *line) {
    Check(write(parentWrite, line, strlen(line)) == (ssize_t)strlen(line), "parent command");
}
static void QueryCase(NSData *response, uint8_t signal, NSData *following, NSUInteger split, BOOL bytewise, BOOL accepted, BOOL rejected) {
    ResetParent();
    DirectPlaybackProbe *probe = Probe();
    TestInput *input = (id)probe.input;
    TestOutput *output = (id)probe.output;
    __block NSUInteger markers = 0;
    output.onWrite = ^(NSData *packet) {
        const uint8_t *bytes = packet.bytes;
        if (bytes[0] == 0x10 && bytes[1] == signal) Chunks(input, response, split, bytewise);
        else if (bytes[0] == 0xF0 && bytes[1] == 0x3F) {
            markers++;
            Chunks(input, following, split, bytewise);
        }
    };
    uint8_t transaction = 1;
    NSData *reply = Query(probe, &transaction, signal, [NSData data]);
    Check(accepted ? [reply isEqualToData:response] : reply == nil, "actual Query result");
    Check(probe.lastRejected == rejected, "actual Query rejection");
    Check(transaction == 2, "transaction advance");
    Check(markers == (FixedResponseLength(response.bytes, response.length, 1, signal) ? 0 : 1), "marker only variable response");
    Check(!probe.pending.length && !probe.framingUncertain && !probe.failed, "response accounted");
    output.onWrite = nil;
}

static void UnmatchedResponseCase(NSData *foreign, NSUInteger boundary, NSUInteger split, BOOL bytewise) {
    ResetParent();
    DirectPlaybackProbe *probe = Probe();
    TestInput *input = (id)probe.input;
    TestOutput *output = (id)probe.output;
    NSData *accepted = Hex(@"72 06");
    NSMutableData *incoming = [NSMutableData data];
    if (boundary == 2) [incoming appendData:accepted];
    [incoming appendData:foreign];
    if (boundary == 1) [incoming appendData:accepted];
    if (boundary >= 2) [incoming appendData:Hex(@"20 01")];
    if (boundary == 0 || boundary == 3) Chunks(input, incoming, split, bytewise);
    output.onWrite = ^(NSData *packet) {
        if ([packet isEqualToData:Hex(@"70 06 0c")]) {
            if (boundary == 0) Chunks(input, accepted, split, bytewise);
            else Chunks(input, incoming, split, bytewise);
        } else {
            Check(boundary >= 2 && [packet isEqualToData:Hex(@"22 01 04 00")], "only peer discovery receives a reply");
            ParentLine("media-prepared\n");
        }
    };
    if (boundary < 3) {
        uint8_t transaction = 7;
        Check([Query(probe, &transaction, 6, Hex(@"0c")) isEqualToData:accepted], "unmatched response cannot satisfy Open");
        Check(transaction == 8 && !probe.lastRejected, "only active response changes transaction result");
    }
    if (boundary >= 2) Check(WaitControl(probe, @"media-prepared"), "control wait drains unmatched response before peer command");
    Check(!probe.pending.length && !probe.framingUncertain && !probe.failed && !probe.streamOpened,
          "unmatched response leaves protocol and stream state intact");
    Check(output.writes.count == (boundary == 2 ? 2 : 1), "unmatched response has no acknowledgment or marker");
    output.onWrite = nil;
}

struct ProtocolThread { int readFD; int writeFD; BOOL stop; };
static void *ParentProtocol(void *opaque) {
    struct ProtocolThread *state = opaque;
    char line[1024];
    NSUInteger length = 0;
    char value;
    while (read(state->readFD, &value, 1) == 1) {
        if (value != '\n') {
            if (length + 1 < sizeof(line)) line[length++] = value;
            continue;
        }
        line[length] = 0;
        length = 0;
        const char *command = NULL;
        if (!strcmp(line, "PREPARE_MEDIA")) command = "media-prepared\n";
        else if (!strncmp(line, "OPEN_ACCEPTED ", 14)) command = "media-ready 2002 679\n";
        else if (!strncmp(line, "START_ACCEPTED ", 15)) command = state->stop ? "stop\n" : "media-finished\n";
        else if (!strcmp(line, "WAIT_MEDIA_CLOSED")) command = "media-closed\n";
        if (command) write(state->writeFD, command, strlen(command));
    }
    close(state->readFD);
    return NULL;
}
static void PlaybackCase(BOOL stop, BOOL wrongConfiguration, uint32_t rate, BOOL cancelConfiguration) {
    ResetParent();
    DirectPlaybackProbe *probe = Probe();
    probe.sampleRate = rate;
    TestInput *input = (id)probe.input;
    TestOutput *output = (id)probe.output;
    __block BOOL closed = NO;
    __block NSUInteger queries = 0;
    output.onWrite = ^(NSData *packet) {
        const uint8_t *bytes = packet.bytes;
        if (bytes[0] & 15) return;
        if (bytes[0] == 0xF0 && bytes[1] == 0x3F) {
            Chunks(input, Hex(@"f1 3f"), 0, NO);
            return;
        }
        queries++;
        if (cancelConfiguration && bytes[1] == 3) { ParentLine("stop\n"); return; }
        uint8_t header[] = {(uint8_t)(bytes[0] | 2), bytes[1]};
        NSMutableData *response = [NSMutableData dataWithBytes:header length:2];
        if (bytes[1] == 1) [response appendData:Hex(@"0c 08")];
        else if (bytes[1] == 12) [response appendData:Hex(@"01 00 07 0a 00 ff 2d 01 00 00 aa 00 3c 07")];
        else if (bytes[1] == 4) [response appendData:ServiceBytes(wrongConfiguration ? 44100 : rate, NO)];
        else if (bytes[1] == 8 || bytes[1] == 10) closed = YES;
        Chunks(input, response, 0, NO);
    };
    int events[2];
    Check(pipe(events) == 0, "event pipe");
    int savedOutput = dup(STDOUT_FILENO);
    Check(dup2(events[1], STDOUT_FILENO) == STDOUT_FILENO, "redirect events");
    close(events[1]);
    struct ProtocolThread state = {events[0], parentWrite, stop};
    pthread_t thread;
    Check(pthread_create(&thread, NULL, ParentProtocol, &state) == 0, "start parent protocol");
    BOOL result = PlaybackSequence(probe);
    fflush(stdout);
    dup2(savedOutput, STDOUT_FILENO);
    close(savedOutput);
    pthread_join(thread, NULL);
    Check(result == (!wrongConfiguration && !cancelConfiguration), "actual playback sequence result");
    if (cancelConfiguration) {
        Check(closed && probe.configurationSent && probe.framingUncertain && queries == 4,
              "canceled configuration sends one Abort without claiming cleanup confirmation");
        output.onWrite = nil;
        return;
    }
    Check(closed && !probe.configurationSent && !probe.configured && !probe.streamOpened, "actual cleanup state");
    Check(!probe.pending.length && !probe.framingUncertain && !probe.failed, "actual sequence parser state");
    Check(queries == (wrongConfiguration ? 5 : 7), "actual sequence query count");
    output.onWrite = nil;
}

int main(void) {
    @autoreleasepool {
        setbuf(stdout, NULL);
        signal(SIGPIPE, SIG_IGN);
        originalInput = dup(STDIN_FILENO);
        parentWrite = -1;
        Check(SelfTest(), "production codec/PeerReply tests");
        for (NSNumber *continuous in @[@NO, @YES]) {
            ResetParent();
            DirectPlaybackProbe *longRunning = Probe();
            longRunning.continuous = continuous.boolValue;
            longRunning.hardDeadline = INFINITY;
            ParentLine("media-finished\n");
            clockCallsUntilAdvance = 2;
            Check(WaitControl(longRunning, @"media-finished") == continuous.boolValue,
                  "continuous playback outlives finite media wait deadline");
            clockOffset = 0;
        }
        DirectPlaybackProbe *bounded = Probe();
        TestInput *boundedInput = (id)bounded.input;
        NSData *chunk = [NSMutableData dataWithLength:4096];
        for (NSUInteger index = 0; index < 20; index++) {
            [boundedInput.chunks addObject:chunk];
            [bounded pollInput];
            [bounded.pending setLength:0];
        }
        Check(!bounded.failed && bounded.raw.length == 65536 && bounded.received == 81920,
              "raw recording stays bounded without limiting connection lifetime");
        [boundedInput.chunks addObject:chunk];
        [bounded pollInput];
        [boundedInput.chunks addObject:chunk];
        [bounded pollInput];
        Check(bounded.failed, "unprocessed signaling input remains bounded");
        NSData *marker = Hex(@"f1 3f");
        NSArray *cases = @[
            @[Hex(@"12 01 04 08 08 08 0c 08"), @1, @YES, @NO],
            @[Hex(@"12 0c 01 00 07 0a 00 ff 2d 01 00 00 aa 00 3c 07 04 02 02 00 08 00"), @12, @YES, @NO],
            @[Hex(@"12 04 01 00 07 0a 00 ff 2d 01 00 00 aa 00 10 01"), @4, @YES, @NO],
            @[Hex(@"12 03"), @3, @YES, @NO],
            @[Hex(@"12 07"), @7, @YES, @NO],
            @[Hex(@"13 03 07 29"), @3, @NO, @YES],
            @[Hex(@"13 04 31"), @4, @NO, @YES]
        ];
        for (NSArray *fixture in cases) {
            NSData *response = fixture[0];
            for (NSUInteger split = 0; split <= response.length; split++)
                QueryCase(response, [fixture[1] unsignedCharValue], marker, split, NO,
                          [fixture[2] boolValue], [fixture[3] boolValue]);
            QueryCase(response, [fixture[1] unsignedCharValue], marker, 0, YES,
                      [fixture[2] boolValue], [fixture[3] boolValue]);
        }
        NSData *discover = cases[0][0];
        QueryCase(discover, 1, Hex(@"20 01 30 02 04 f1 3f"), 1, YES, YES, NO);
        QueryCase(Hex(@"12 0c 01 00 07 0a 00 ff 2d 01 00 00 aa 00 10 01 04 02 f1 3f"),
                  12, marker, 0, YES, YES, NO);
        for (NSData *bad in @[Hex(@"22 01 04 08"), Hex(@"16 01"), Hex(@"12 01 04 08 f1 3f"),
                              Hex(@"12 0c 01 00 07 0a 00 ff 2d 01 00 00 aa 00 10 01 10 07 04 f1 3f")]) {
            ResetParent();
            DirectPlaybackProbe *probe = Probe();
            probe.hardDeadline = MonotonicTime() + 0.05;
            TestInput *input = (id)probe.input;
            TestOutput *output = (id)probe.output;
            output.onWrite = ^(NSData *packet) {
                const uint8_t *bytes = packet.bytes;
                if (bytes[0] == 0x10) Chunks(input, bad, 0, NO);
                else if (bytes[0] == 0xF0) Chunks(input, marker, 0, NO);
            };
            uint8_t transaction = 1;
            uint8_t signal = ((const uint8_t *)bad.bytes)[1];
            Check(Query(probe, &transaction, signal, [NSData data]) == nil && probe.framingUncertain,
                  "wrong label/fragment/premature marker/unsupported alternative fails closed");
            output.onWrite = nil;
        }
        for (NSData *foreign in @[Hex(@"f3 01 31"), Hex(@"f3 01 31 f3 01 31"), Hex(@"73 01 31"),
                                  Hex(@"f2 06"), Hex(@"f3 03 07 29")]) {
            for (NSUInteger boundary = 0; boundary < 4; boundary++) {
                for (NSUInteger split = 0; split <= foreign.length + 4; split++)
                    UnmatchedResponseCase(foreign, boundary, split, NO);
                UnmatchedResponseCase(foreign, boundary, 0, YES);
            }
        }
        QueryCase(Hex(@"12 0c 01 00 07 0a 00 ff 2d 01 00 00 aa 00 10 01 04 03 f3 01 31"),
                  12, marker, 0, YES, YES, NO);
        QueryCase(discover, 1, Hex(@"f1 3f f3 01 31"), 0, NO, YES, NO);
        for (NSUInteger boundary = 0; boundary < 4; boundary++) {
            for (NSData *unframed in @[Hex(@"f2 01 04 08"), Hex(@"f7 01 31"), Hex(@"f1 3f"), Hex(@"f3 3f 31")]) {
                ResetParent();
                DirectPlaybackProbe *probe = Probe();
                probe.hardDeadline = MonotonicTime() + 0.025;
                TestInput *input = (id)probe.input;
                TestOutput *output = (id)probe.output;
                NSMutableData *incoming = [NSMutableData data];
                if (boundary == 2) [incoming appendData:Hex(@"72 06")];
                [incoming appendData:unframed];
                if (boundary == 0 || boundary == 3) Chunks(input, incoming, 0, NO);
                output.onWrite = ^(NSData *packet) {
                    Check([packet isEqualToData:Hex(@"70 06 0c")], "unframeable input receives no reply");
                    Chunks(input, incoming, 0, NO);
                };
                if (boundary == 3) Check(!WaitControl(probe, @"media-prepared"), "control wait rejects unframeable response");
                else {
                    uint8_t transaction = 7;
                    Check(Query(probe, &transaction, 6, Hex(@"0c")) == nil, "query boundary rejects unframeable response");
                }
                Check(probe.framingUncertain && !probe.streamOpened &&
                      output.writes.count == (boundary == 1 || boundary == 2 ? 1 : 0),
                      "unframeable response fails closed at every confirmed boundary");
                output.onWrite = nil;
            }
        }
        for (NSString *hex in @[@"f3 01 31", @"f3 01 31 73 06 31", @"f3 01", @"f2 01 04 08 72 06",
                                @"f7 01 31 72 06", @"f1 3f 72 06", @"f3 3f 31 72 06"]) {
            NSData *incoming = Hex(hex);
            for (NSUInteger split = 0; split <= incoming.length + 1; split++) {
                ResetParent();
                DirectPlaybackProbe *probe = Probe();
                probe.hardDeadline = MonotonicTime() + 0.025;
                TestInput *input = (id)probe.input;
                TestOutput *output = (id)probe.output;
                output.onWrite = ^(NSData *packet) {
                    Check([packet isEqualToData:Hex(@"70 06 0c")], "failed Open writes only its own command");
                    Chunks(input, incoming, split, split > incoming.length);
                };
                uint8_t transaction = 7;
                BOOL rejected = [hex isEqualToString:@"f3 01 31 73 06 31"];
                Check(Query(probe, &transaction, 6, Hex(@"0c")) == nil && probe.lastRejected == rejected,
                      "captured foreign rejection cannot replace missing or rejected Open acceptance");
                Check(!probe.streamOpened && probe.framingUncertain == !rejected && output.writes.count == 1,
                      "unframeable or incomplete input fails closed without protocol writes");
                output.onWrite = nil;
            }
        }
        ResetParent();
        DirectPlaybackProbe *rollover = Probe();
        TestInput *rollInput = (id)rollover.input;
        TestOutput *rollOutput = (id)rollover.output;
        rollOutput.onWrite = ^(NSData *packet) {
            const uint8_t *bytes = packet.bytes;
            uint8_t response[] = {(uint8_t)(bytes[0] | 2), bytes[1]};
            Chunks(rollInput, [NSData dataWithBytes:response length:2], 1, YES);
        };
        uint8_t transaction = 14;
        Check(EmptyAcceptance(Query(rollover, &transaction, 6, Hex(@"0c"))) && transaction == 0, "skip reserved label");
        Check(EmptyAcceptance(Query(rollover, &transaction, 6, Hex(@"0c"))) && transaction == 1, "label zero remains valid");
        rollOutput.onWrite = nil;
        ResetParent();
        DirectPlaybackProbe *idle = Probe();
        idle.configured = YES;
        TestInput *idleInput = (id)idle.input;
        TestOutput *idleOutput = (id)idle.output;
        Chunks(idleInput, Hex(@"20 0d 04 00 64"), 0, YES);
        idleOutput.onWrite = ^(NSData *packet) {
            Check([packet isEqualToData:Hex(@"22 0d")], "idle delay accepted");
            ParentLine("media-prepared\n");
        };
        Check(WaitControl(idle, @"media-prepared"), "peer command serviced without parent activity");
        Check(idleOutput.writes.count == 1 && !idle.pending.length, "idle command accounted");
        idleOutput.onWrite = nil;
        for (NSUInteger variant = 0; variant < 3; variant++) {
            ResetParent();
            DirectPlaybackProbe *cancel = Probe();
            TestOutput *output = (id)cancel.output;
            output.onWrite = ^(__unused NSData *packet) {
                if (variant == 0) ParentLine("stop\n");
                else if (variant == 1) { close(parentWrite); parentWrite = -1; }
                else interrupted = SIGTERM;
            };
            uint8_t label = 1;
            double began = MonotonicTime();
            Check(Query(cancel, &label, 1, [NSData data]) == nil && cancel.stopRequested && cancel.framingUncertain,
                  "cancel/parent EOF/signal interrupts active query");
            Check(MonotonicTime() - began < 0.1 && output.writes.count == 1, "bounded cancellation sends no new query");
            output.onWrite = nil;
        }
        ResetParent();
        DirectPlaybackProbe *peerClose = Probe();
        peerClose.configured = YES;
        peerClose.configurationSent = YES;
        peerClose.streamOpened = YES;
        Chunks((id)peerClose.input, Hex(@"20 08 04"), 0, YES);
        Check(!WaitControl(peerClose, @"media-finished") && peerClose.peerStopped &&
              !peerClose.configurationSent && [((TestOutput *)peerClose.output).writes.lastObject isEqualToData:Hex(@"22 08")],
              "peer Close during playback wait is answered and stops playback without parent activity");
        ResetParent();
        DirectPlaybackProbe *partialWrite = Probe();
        ((TestOutput *)partialWrite.output).shortWrite = YES;
        uint8_t partialTransaction = 1;
        Check(!Query(partialWrite, &partialTransaction, 3, Hex(@"0c 04")) && partialWrite.failed &&
              partialWrite.configurationSent && partialWrite.framingUncertain, "short configuration write keeps ownership uncertain");
        ResetParent();
        DirectPlaybackProbe *nilOpen = Probe();
        nilOpen.channel = nil;
        nilOpen.openRequested = YES;
        Check(!RecordOpen(nilOpen, nil, 0) && nilOpen.openIndeterminate && nilOpen.openDone, "nil zero open indeterminate");
        DirectPlaybackProbe *lateOpen = Probe();
        TestChannel *channel = (id)lateOpen.channel;
        lateOpen.openRequested = YES;
        lateOpen.stopRequested = YES;
        Check(RecordOpen(lateOpen, (id)channel, 0) && lateOpen.channel == (id)channel && lateOpen.stopRequested,
              "late success after stop remains owned");
        Check(RecordClosed(lateOpen, (id)channel, 1818) && lateOpen.closed, "matched callback terminal despite close status convention");
        Check(!RecordOpen(lateOpen, (id)channel, 0) && lateOpen.failed, "duplicate open rejected");
        DirectPlaybackProbe *wrongClose = Probe();
        TestChannel *other = [TestChannel new];
        other.PSM = 0x19;
        other.cid = wrongClose.realCID;
        Check(!RecordClosed(wrongClose, (id)other, 0) && !wrongClose.closed && wrongClose.failed, "same CID different object not closure");
        DirectPlaybackProbe *noTerminal = Probe();
        noTerminal.hardDeadline = MonotonicTime() + 0.02;
        ((TestInput *)noTerminal.input).ended = YES;
        noTerminal.closing = YES;
        Check(!WaitTransportClosed(noTerminal) && !noTerminal.closed, "EOF alone never terminal callback proof");
        DirectPlaybackProbe *oversized = Probe();
        [((TestInput *)oversized.input).chunks addObject:[NSMutableData dataWithLength:4097]];
        [oversized pollInput];
        [oversized pollInput];
        Check(oversized.failed && oversized.pending.length <= 4096, "bounded signaling buffer");
        Check(AcquisitionTrigger(@"acquire 100 200", 100, 300), "fresh acquisition");
        for (NSString *invalid in @[@"acquire 99 200", @"acquire 100 100", @"acquire 100 301", @"acquire 100 200 extra", @"stop"])
            Check(!AcquisitionTrigger(invalid, 100, 300), "bad acquisition rejected");
        Check(!AcquisitionTrigger(@"acquire 100 200", 100, 200 + NSEC_PER_SEC + 1), "stale acquisition rejected");
        for (NSNumber *rate in @[@44100, @48000, @88200, @96000]) PlaybackCase(NO, NO, rate.unsignedIntValue, NO);
        PlaybackCase(YES, NO, 48000, NO);
        PlaybackCase(NO, YES, 48000, NO);
        PlaybackCase(NO, NO, 48000, YES);
        dup2(originalInput, STDIN_FILENO);
        close(originalInput);
        if (parentWrite >= 0) close(parentWrite);
        printf("SIGNALING_TESTS_PASS checks=%lu hardware_access=0\n", checks);
        return 0;
    }
}
