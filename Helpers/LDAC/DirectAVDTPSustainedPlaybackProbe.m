#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <IOBluetooth/IOBluetooth.h>
#include "LDACParentLifetime.h"
#include <inttypes.h>
#import <objc/runtime.h>
#include <poll.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <time.h>
#include <math.h>

#ifndef ACOUPLET_LDAC_PROBE_ONLY
#define ACOUPLET_LDAC_PROBE_ONLY 1
#endif

@interface CBClassicPeer : CBPeer
@property(readonly) NSInteger internalState;
@property(readonly) id manager;
- (id)sendInternalSyncMsg:(int)message args:(NSDictionary *)arguments;
- (void)handleGetPeerState:(NSDictionary *)reply;
@property(copy) void (^connectL2CAPCallback)(CBL2CAPChannel *, NSInteger);
@property(copy) void (^disconnectL2CAPCallback)(CBL2CAPChannel *, NSInteger);
- (void)openL2CAPChannel:(UInt16)psm;
- (void)closeL2CAPChannel:(UInt16)psm;
@end

@interface CBClassicManager : CBManager
@property(readonly) BOOL tccApproved;
@property(readonly) BOOL tccComplete;
@property(readonly) BOOL tccRequired;
- (instancetype)initWithQueue:(dispatch_queue_t)queue options:(NSDictionary *)options;
- (CBClassicPeer *)peerWithIdentifier:(NSUUID *)identifier;
- (void)checkForTCC;
- (CBClassicPeer *)retrievePeerWithAddress:(NSString *)address;
@end

@interface CBL2CAPChannel (ChannelInspection)
@property(readonly) UInt16 cid;
@property(readonly) UInt16 outgoingMTU;
@property(readonly) int socketFD;
@end

static volatile sig_atomic_t interrupted;
static void Stop(int number) { interrupted = number; }

static void RunLoopFor(NSTimeInterval seconds) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}

static double MonotonicTime(void) {
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1000000000.0;
}

static NSString *NormalizeAddress(const char *value) {
    if (strlen(value) != 17 || (value[2] != ':' && value[2] != '-')) return nil;
    for (NSUInteger index = 0; index < 17; index++) {
        if (index % 3 == 2) {
            if (value[index] != value[2]) return nil;
        } else if (!((value[index] >= '0' && value[index] <= '9') ||
                     (value[index] >= 'a' && value[index] <= 'f') ||
                     (value[index] >= 'A' && value[index] <= 'F'))) return nil;
    }
    return [[[NSString stringWithUTF8String:value] uppercaseString] stringByReplacingOccurrencesOfString:@":" withString:@"-"];
}

static uint8_t RateBit(uint32_t sampleRate) {
    switch (sampleRate) {
        case 44100: return 0x20;
        case 48000: return 0x10;
        case 88200: return 0x08;
        case 96000: return 0x04;
        default: return 0;
    }
}

static BOOL ParseSampleRate(const char *input, uint32_t *sampleRate) {
    if (input[0] < '0' || input[0] > '9') return NO;
    errno = 0;
    char *end = NULL;
    unsigned long parsed = strtoul(input, &end, 10);
    if (errno || *end || parsed > UINT32_MAX || !RateBit((uint32_t)parsed)) return NO;
    *sampleRate = (uint32_t)parsed;
    return YES;
}

typedef struct {
    NSUInteger responseLength;
    NSUInteger consumed;
    NSUInteger commands;
    BOOL rejected;
} Parsed;

static NSUInteger FixedCommandLength(const uint8_t *bytes, NSUInteger length) {
    if (length < 2 || (bytes[0] & 15) || (bytes[1] & 0xC0)) return 0;
    switch (bytes[1]) {
        case 1: return 2;
        case 2: case 4: case 6: case 8: case 10: case 12: return 3;
        case 13: return 5;
        default: return 0;
    }
}

static NSUInteger FixedResponseLength(const uint8_t *bytes, NSUInteger length, uint8_t transaction, uint8_t signal) {
    if (length < 2 || bytes[1] != signal || (bytes[0] >> 4) != transaction || (bytes[0] & 12)) return 0;
    if ((bytes[0] & 3) == 2) return signal == 3 || (signal >= 6 && signal <= 10) ? 2 : 0;
    if ((bytes[0] & 3) != 3) return 0;
    switch (signal) {
        case 1: case 2: case 4: case 6: case 8: case 12: return 3;
        case 3: case 7: case 9: return 4;
        default: return 0;
    }
}

static BOOL FragmentedCommandPossible(const uint8_t *bytes, NSUInteger length) {
    uint8_t command[] = {(uint8_t)(bytes[0] & 0xF0), bytes[2]};
    if (bytes[1] != 2 || FixedCommandLength(command, sizeof(command)) != 3) return YES;
    uint8_t endHeader = (bytes[0] & 0xF0) | 12;
    for (NSUInteger startLength = 3; startLength <= 4; startLength++) {
        if (length <= startLength || bytes[startLength] == endHeader || (bytes[startLength] & 15) == 4) return YES;
        if (!(bytes[startLength] & 15) &&
            (length == startLength + 1 || bytes[startLength + 1] == 10)) return YES;
    }
    return NO;
}

static void Candidate(const uint8_t *bytes, NSUInteger length, NSUInteger end,
                      BOOL rejected, Parsed *parsed, NSUInteger *solutions, BOOL *unsupported) {
    NSUInteger offset = end, commands = 0;
    while (offset < length) {
        if (length - offset >= 2 && bytes[offset] == 0xF1 && bytes[offset + 1] == 0x3F) {
            *parsed = (Parsed){end, offset + 2, commands, rejected};
            (*solutions)++;
            return;
        }
        NSUInteger remaining = length - offset;
        if (remaining >= 2 && !(bytes[offset] & 3)) {
            uint8_t type = bytes[offset] & 12;
            uint8_t signal = bytes[offset + 1];
            if ((!type && (signal == 3 || signal == 5 || signal == 7 || signal == 9 || signal == 11)) ||
                (type == 4 && remaining >= 3 && bytes[offset + 2] >= 1 && bytes[offset + 2] <= 13 &&
                 FragmentedCommandPossible(bytes + offset, remaining))) {
                *unsupported = YES;
                return;
            }
        }
        NSUInteger size = FixedCommandLength(bytes + offset, length - offset);
        if (!size || length - offset < size) return;
        offset += size;
        commands++;
    }
}

static int Parse(const uint8_t *bytes, NSUInteger length, uint8_t transaction, uint8_t signal, Parsed *parsed) {
    *parsed = (Parsed){0};
    if (length < 2) return 0;
    if (bytes[1] != signal || (bytes[0] >> 4) != transaction || (bytes[0] & 12)) return -1;
    BOOL rejected = (bytes[0] & 3) == 3;
    if (!rejected && (bytes[0] & 3) != 2) return -1;
    NSUInteger solutions = 0;
    BOOL unsupported = NO;
    if (rejected) {
        NSUInteger size;
        switch (signal) {
            case 1: case 2: case 4: case 6: case 8: case 12: size = 3; break;
            case 3: case 7: case 9: size = 4; break;
            default: return -1;
        }
        if (length >= size) Candidate(bytes, length, size, YES, parsed, &solutions, &unsupported);
    } else if (signal == 3 || (signal >= 6 && signal <= 10)) {
        Candidate(bytes, length, 2, NO, parsed, &solutions, &unsupported);
    } else if (signal == 1) {
        uint64_t seen = 0;
        for (NSUInteger offset = 2; offset + 2 <= length; offset += 2) {
            uint8_t seid = bytes[offset] >> 2, info = bytes[offset + 1];
            if ((bytes[offset] & 1) || seid < 1 || seid > 62 || (seen & (1ULL << seid)) ||
                (info & 7) || (info >> 4) > 2) break;
            seen |= 1ULL << seid;
            Candidate(bytes, length, offset + 2, NO, parsed, &solutions, &unsupported);
        }
    } else if (signal == 2 || signal == 4 || signal == 12) {
        unsigned seen = 0;
        NSUInteger offset = 2;
        NSUInteger alternateSolutions = 0;
        Parsed alternate;
        Candidate(bytes, length, offset, NO, &alternate, &alternateSolutions, &unsupported);
        if (alternateSolutions) unsupported = YES;
        while (offset + 2 <= length) {
            uint8_t category = bytes[offset], size = bytes[offset + 1];
            if (category < 1 || category > 8 || (seen & (1U << category))) break;
            if ((category == 1 && size != 0) || (category == 7 && size < 2)) break;
            seen |= 1U << category;
            offset += 2 + size;
            if (offset > length) break;
            if ((seen & (1U << 1)) && (seen & (1U << 7))) Candidate(bytes, length, offset, NO, parsed, &solutions, &unsupported);
            else {
                alternateSolutions = 0;
                Candidate(bytes, length, offset, NO, &alternate, &alternateSolutions, &unsupported);
                if (alternateSolutions) unsupported = YES;
            }
        }
    } else return -1;
    if (solutions > 1) return -2;
    if (solutions && unsupported) return -3;
    return solutions == 1 ? 1 : 0;
}


@interface DirectPlaybackProbe : NSObject
@property BOOL openRequested;
@property BOOL openDone;
@property BOOL openIndeterminate;
@property NSInteger openError;
@property BOOL framingUncertain;
@property double hardDeadline;
@property(copy) BOOL (^callbacksIntact)(void);
@property BOOL closed;
@property BOOL closing;
@property BOOL failed;
@property NSUInteger received;
@property UInt16 realCID;
@property(strong) CBL2CAPChannel *channel;
@property(strong) NSInputStream *input;
@property(strong) NSOutputStream *output;
@property NSMutableData *pending;
@property NSMutableData *raw;
@property BOOL continuous;
@property NSMutableData *controlPending;
@property BOOL stopRequested;
@property BOOL stdinEnded;
@property BOOL protocolCleanup;
@property BOOL inputEnded;
@property BOOL configurationSent;
@property BOOL configured;
@property BOOL streamOpened;
@property BOOL peerStopped;
@property BOOL delayReporting;
@property BOOL lastRejected;
@property BOOL mediaExpected;
@property UInt8 selectedSink;
@property UInt16 mediaCID;
@property uint32_t sampleRate;
@property(strong) NSString *quality;
- (void)pollInput;
@end

@implementation DirectPlaybackProbe
- (void)pollInput {
    if (interrupted) self.stopRequested = YES;
    if (self.callbacksIntact && !self.callbacksIntact()) self.failed = YES;
    if (self.closed || self.failed || !self.input) return;
    while (self.input.hasBytesAvailable) {
        uint8_t bytes[4096];
        NSInteger length = [self.input read:bytes maxLength:sizeof(bytes)];
        printf("RX time=%.6f channel=%p length=%ld bytes=", NSDate.date.timeIntervalSince1970,
               (__bridge void *)self.channel, length);
        for (NSInteger i = 0; i < MIN(length, 256); i++) printf("%s%02X", i ? " " : "", bytes[i]);
        if (length > 256) printf(" ...");
        printf("\n");
        if (length <= 0) {
            if (!length) self.inputEnded = YES;
            if (!self.closing) self.failed = YES;
            return;
        }
        if (self.pending.length + (NSUInteger)length > 4096) {
            self.failed = YES;
            return;
        }
        [self.pending appendBytes:bytes length:(NSUInteger)length];
        [self.raw appendBytes:bytes length:MIN((NSUInteger)length, 65536 - self.raw.length)];
        self.received += (NSUInteger)length;
    }
    if (self.input.streamStatus == NSStreamStatusAtEnd) self.inputEnded = YES;
    if (!self.closing && (self.input.streamStatus == NSStreamStatusError || self.inputEnded)) {
        printf("INPUT_TERMINAL time=%.6f status=%lu error=%s\n", NSDate.date.timeIntervalSince1970,
               self.input.streamStatus, self.input.streamError.description.UTF8String);
        self.failed = YES;
    }
}
@end

static NSString *ReadLine(DirectPlaybackProbe *probe, double deadline, BOOL requireLink, NSTimeInterval interval) {
    deadline = MIN(deadline, probe.hardDeadline);
    while (!probe.stdinEnded && (!requireLink || (!probe.closed && !probe.failed)) && MonotonicTime() < deadline) {
        if (interrupted && !probe.stopRequested) { probe.stopRequested = YES; return @"stop"; }
        struct pollfd descriptor = {STDIN_FILENO, POLLIN, 0};
        int ready = poll(&descriptor, 1, 0);
        if (ready < 0) {
            if (errno == EINTR) continue;
            probe.failed = YES;
            break;
        }
        if (descriptor.revents & (POLLIN | POLLHUP | POLLERR)) {
            char value;
            ssize_t length = read(STDIN_FILENO, &value, 1);
            if (length != 1) {
                if (length < 0 && errno == EINTR) continue;
                probe.stdinEnded = YES;
                probe.stopRequested = YES;
                printf("PARENT_INPUT_END errno=%d\n", length < 0 ? errno : 0);
                break;
            }
            if (value == '\n') {
                NSString *line = [[NSString alloc] initWithData:probe.controlPending encoding:NSUTF8StringEncoding];
                [probe.controlPending setLength:0];
                if (!line) probe.failed = YES;
                if ([line isEqualToString:@"stop"]) {
                    probe.stopRequested = YES;
                    printf("STOP_REQUESTED\n");
                }
                return line;
            }
            if (!value || probe.controlPending.length == 127) { probe.failed = YES; break; }
            [probe.controlPending appendBytes:&value length:1];
            continue;
        }
        [probe pollInput];
        RunLoopFor(interval);
    }
    return nil;
}

static NSArray<NSNumber *> *DecodeReply(NSData *reply, uint8_t transaction, uint8_t signal,
                                      uint8_t seid, BOOL emit) {
    const uint8_t *bytes = reply.bytes;
    NSUInteger length = reply.length;
    if (length < 2 || bytes[0] != ((transaction << 4) | 2) || bytes[1] != signal) return nil;
    NSMutableArray<NSNumber *> *sinks = [NSMutableArray array];
    if (signal == 1) {
        if (length < 4 || (length - 2) % 2 || length > 126) return nil;
        BOOL seen[63] = {NO};
        for (NSUInteger i = 2; i < length; i += 2) {
            uint8_t endpoint = bytes[i] >> 2;
            if (!endpoint || endpoint > 62 || seen[endpoint] || bytes[i] & 1 || bytes[i + 1] & 7)
                return nil;
            seen[endpoint] = YES;
            BOOL inUse = bytes[i] & 2;
            uint8_t mediaType = bytes[i + 1] >> 4;
            BOOL sink = bytes[i + 1] & 8;
            if (emit) printf("SEP %u inUse=%d mediaType=%u sink=%d\n", endpoint, inUse, mediaType, sink);
            if (!inUse && mediaType == 0 && sink) [sinks addObject:@(endpoint)];
        }
    } else {
        BOOL seen[9] = {NO};
        for (NSUInteger offset = 2; offset < length;) {
            if (length - offset < 2) return nil;
            uint8_t category = bytes[offset++];
            uint8_t size = bytes[offset++];
            if (!category || category > 8 || seen[category] || size > length - offset) return nil;
            seen[category] = YES;
            if (category == 1 && size != 0) return nil;
            if (category == 7) {
                if (size < 2 || bytes[offset] != 0) return nil;
                if (bytes[offset + 1] == 0xFF && size < 8) return nil;
                const uint8_t ldac[] = {0x00, 0xFF, 0x2D, 0x01, 0x00, 0x00, 0xAA, 0x00};
                BOOL isLDAC = size >= sizeof(ldac) && memcmp(bytes + offset, ldac, sizeof(ldac)) == 0;
                if (isLDAC && size != 10) return nil;
            }
            offset += size;
        }
        if (!seen[1] || !seen[7]) return nil;
        if (emit) {
            for (NSUInteger offset = 2; offset < length;) {
                uint8_t category = bytes[offset++];
                uint8_t size = bytes[offset++];
                printf("CAPABILITY SEID=%u category=%u bytes=", seid, category);
                for (NSUInteger i = 0; i < size; i++) printf("%s%02X", i ? " " : "", bytes[offset + i]);
                printf("\n");
                const uint8_t ldac[] = {0x00, 0xFF, 0x2D, 0x01, 0x00, 0x00, 0xAA, 0x00};
                if (category == 7 && size == 10 && memcmp(bytes + offset, ldac, sizeof(ldac)) == 0)
                    printf("LDAC SEID=%u rates=%02X modes=%02X supportsStereo=%d\n", seid,
                           bytes[offset + 8], bytes[offset + 9],
                           !!(bytes[offset + 9] & 1));
                offset += size;
            }
        }
    }
    return sinks;
}

static BOOL SendSignal(DirectPlaybackProbe *probe, NSData *packet) {
    if (probe.closed || probe.failed || !probe.output || packet.length > (NSUInteger)MIN(probe.channel.outgoingMTU, 2570))
        return NO;
    const uint8_t *bytes = packet.bytes;
    printf("TX_BEGIN time=%.6f bytes=", NSDate.date.timeIntervalSince1970);
    for (NSUInteger i = 0; i < packet.length; i++) printf("%s%02X", i ? " " : "", bytes[i]);
    printf("\n");
    NSInteger sent = [probe.output write:bytes maxLength:packet.length];
    printf("TX_RETURN time=%.6f sent=%ld expected=%lu errno=%d inStatus=%lu outStatus=%lu\n",
           NSDate.date.timeIntervalSince1970, sent, packet.length, sent < 0 ? errno : 0,
           probe.input.streamStatus, probe.output.streamStatus);
    if (sent != (NSInteger)packet.length) {
        printf("PUBLIC_STREAM_WRITE_FAILED error=%s\n", probe.output.streamError.description.UTF8String);
        probe.failed = YES;
        return NO;
    }
    return YES;
}

static NSData *ServiceBytes(uint32_t sampleRate, BOOL delayReporting) {
    const uint8_t bytes[] = {0x01, 0x00, 0x07, 0x0A, 0x00, 0xFF, 0x2D, 0x01,
                             0x00, 0x00, 0xAA, 0x00, RateBit(sampleRate), 0x01, 0x08, 0x00};
    return [NSData dataWithBytes:bytes length:delayReporting ? sizeof(bytes) : sizeof(bytes) - 2];
}

static NSData *PeerReply(DirectPlaybackProbe *probe, NSData *packet) {
    const uint8_t *bytes = packet.bytes;
    if (packet.length < 2 || (bytes[0] & 15) || bytes[1] & 0xC0) return nil;
    uint8_t response[] = {(uint8_t)((bytes[0] & 0xF0) | 2), bytes[1], 0, 0};
    uint8_t error = 0;
    switch (bytes[1]) {
        case 1:
            if (packet.length != 2) { error = 0x11; break; }
            response[2] = probe.configured ? 0x06 : 0x04;
            return [NSData dataWithBytes:response length:4];
        case 2:
        case 4:
        case 12:
            if (packet.length != 3) { error = 0x11; break; }
            if (bytes[2] != 0x04) { error = 0x12; break; }
            if (bytes[1] == 4 && !probe.configured) { error = 0x31; break; }
            {
                NSMutableData *reply = [NSMutableData dataWithBytes:response length:2];
                [reply appendData:ServiceBytes(probe.sampleRate, bytes[1] == 12 || (bytes[1] == 4 && probe.delayReporting))];
                return reply;
            }
        case 8:
            if (packet.length != 3) { error = 0x11; break; }
            if (bytes[2] != 0x04) { error = 0x12; break; }
            if (!probe.streamOpened) { error = 0x31; break; }
            probe.peerStopped = YES;
            probe.configured = NO;
            probe.configurationSent = NO;
            probe.streamOpened = NO;
            return [NSData dataWithBytes:response length:2];
        case 10:
            if (packet.length != 3 || bytes[2] != 0x04) return nil;
            probe.peerStopped = YES;
            probe.configured = NO;
            probe.configurationSent = NO;
            probe.streamOpened = NO;
            return [NSData dataWithBytes:response length:2];
        case 13:
            if (packet.length != 5) { error = 0x11; break; }
            if (bytes[2] != 0x04) { error = 0x12; break; }
            if (!probe.configured && !probe.configurationSent) { error = 0x31; break; }
            return [NSData dataWithBytes:response length:2];
        case 3:
        case 5:
            response[0] |= 1;
            response[2] = 0;
            response[3] = 0x19;
            return [NSData dataWithBytes:response length:4];
        default:
            if (bytes[1] >= 1 && bytes[1] <= 13) return nil;
            response[0] = (bytes[0] & 0xF0) | 1;
            return [NSData dataWithBytes:response length:2];
    }
    response[0] |= 1;
    response[2] = error;
    return [NSData dataWithBytes:response length:3];
}

static BOOL HandlePeerCommand(DirectPlaybackProbe *probe, NSData *packet) {
    const uint8_t *bytes = packet.bytes;
    NSData *reply = PeerReply(probe, packet);
    if (!reply) {
        printf("PEER_COMMAND_UNSUPPORTED\n");
        return NO;
    }
    printf("PEER_COMMAND transaction=%u signal=%02X length=%lu\n", bytes[0] >> 4, bytes[1], packet.length);
    if (!SendSignal(probe, reply)) return NO;
    if (bytes[1] == 13 && packet.length == 5 && (((const uint8_t *)reply.bytes)[0] & 3) == 2)
        printf("DELAY_REPORT value=%u units=0.1ms\n", (bytes[3] << 8) | bytes[4]);
    if (probe.peerStopped) printf("STREAM_CLOSED peerSignal=%02X\n", bytes[1]);
    return YES;
}

static int ServicePendingSignals(DirectPlaybackProbe *probe, uint8_t transaction, uint8_t signal) {
    while (probe.pending.length && !probe.failed && !probe.closed) {
        if (probe.pending.length < 2) return 0;
        const uint8_t *bytes = probe.pending.bytes;
        if (bytes[0] & 3) {
            if ((bytes[0] >> 4) == transaction && bytes[1] == signal && signal) return 1;
            NSUInteger length = FixedResponseLength(bytes, probe.pending.length, bytes[0] >> 4, bytes[1]);
            if (!length) {
                printf("UNMATCHED_RESPONSE_FRAMING_UNSUPPORTED\n");
                probe.framingUncertain = YES;
                return -1;
            }
            if (probe.pending.length < length) return 0;
            printf("UNMATCHED_RESPONSE_DISCARDED transaction=%u signal=%02X length=%lu\n", bytes[0] >> 4, bytes[1], length);
            [probe.pending replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
            continue;
        }
        NSUInteger length = FixedCommandLength(bytes, probe.pending.length);
        if (!length) {
            printf("PEER_COMMAND_FRAMING_UNSUPPORTED\n");
            probe.framingUncertain = YES;
            return -1;
        }
        if (probe.pending.length < length) return 0;
        NSData *packet = [probe.pending subdataWithRange:NSMakeRange(0, length)];
        [probe.pending replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
        if (!HandlePeerCommand(probe, packet)) {
            probe.framingUncertain = YES;
            return -1;
        }
    }
    return 1;
}

static BOOL QueryCancelled(DirectPlaybackProbe *probe) {
    NSString *line = ReadLine(probe, MonotonicTime() + 0.001, NO, 0.0001);
    if (line && ![line isEqualToString:@"stop"]) {
        printf("UNEXPECTED_CONTROL_DURING_QUERY\n");
        probe.failed = YES;
    }
    return probe.stdinEnded || probe.closed || probe.failed || probe.peerStopped ||
        (probe.stopRequested && !probe.protocolCleanup);
}

static NSData *AwaitResponse(DirectPlaybackProbe *probe, uint8_t transaction, uint8_t signal) {
    probe.lastRejected = NO;
    BOOL markerSent = NO;
    double deadline = MIN(probe.hardDeadline, MonotonicTime() + 3);
    while (MonotonicTime() < deadline && !QueryCancelled(probe)) {
        [probe pollInput];
        int serviced = ServicePendingSignals(probe, transaction, signal);
        if (serviced < 0 || probe.peerStopped) break;
        if (!serviced) continue;
        Parsed parsed = {0};
        NSUInteger fixed = FixedResponseLength(probe.pending.bytes, probe.pending.length, transaction, signal);
        int result;
        if (fixed) {
            if (probe.pending.length < fixed) continue;
            parsed = (Parsed){fixed, fixed, 0, ((((const uint8_t *)probe.pending.bytes)[0] & 3) == 3)};
            result = 1;
        } else result = Parse(probe.pending.bytes, probe.pending.length, transaction, signal, &parsed);
        if (result < 0 || (result == 1 && !fixed && !markerSent)) {
            printf("RESPONSE_FRAMING_REJECT result=%d marker_sent=%d\n", result, markerSent);
            break;
        }
        if (!fixed && !markerSent && probe.pending.length >= 2) {
            const uint8_t marker[] = {0xF0, 0x3F};
            if (!SendSignal(probe, [NSData dataWithBytes:marker length:sizeof(marker)])) break;
            markerSent = YES;
        }
        if (result != 1) continue;
        NSData *reply = [probe.pending subdataWithRange:NSMakeRange(0, parsed.responseLength)];
        NSData *commands = [probe.pending subdataWithRange:NSMakeRange(parsed.responseLength,
            parsed.consumed - parsed.responseLength - (fixed ? 0 : 2))];
        [probe.pending replaceBytesInRange:NSMakeRange(0, parsed.consumed) withBytes:NULL length:0];
        probe.framingUncertain = NO;
        const uint8_t *bytes = commands.bytes;
        for (NSUInteger offset = 0; offset < commands.length;) {
            NSUInteger length = FixedCommandLength(bytes + offset, commands.length - offset);
            if (!length || length > commands.length - offset ||
                !HandlePeerCommand(probe, [commands subdataWithRange:NSMakeRange(offset, length)])) {
                probe.framingUncertain = YES;
                return nil;
            }
            offset += length;
        }
        if (ServicePendingSignals(probe, 0, 0) < 0) return nil;
        if (probe.peerStopped) return nil;
        probe.lastRejected = parsed.rejected;
        if (parsed.rejected) {
            printf("RESPONSE_REJECTED transaction=%u signal=%02X error=%02X\n", transaction, signal,
                   ((const uint8_t *)reply.bytes)[reply.length - 1]);
            return nil;
        }
        printf("RESPONSE_ACCEPTED transaction=%u signal=%02X length=%lu CID=%04X\n",
               transaction, signal, reply.length, probe.realCID);
        return reply;
    }
    printf("RESPONSE_FAILED transaction=%u signal=%02X rejected=%d framing_unconfirmed=1\n",
           transaction, signal, probe.lastRejected);
    return nil;
}

static NSData *Query(DirectPlaybackProbe *probe, uint8_t *transaction, uint8_t signal, NSData *payload) {
    probe.lastRejected = NO;
    if (*transaction >= 15 || probe.framingUncertain || QueryCancelled(probe)) return nil;
    double deadline = MIN(probe.hardDeadline, MonotonicTime() + 3);
    [probe pollInput];
    while (probe.pending.length && !QueryCancelled(probe) && MonotonicTime() < deadline) {
        if (ServicePendingSignals(probe, 0, 0) < 0) return nil;
        if (!probe.pending.length) break;
        RunLoopFor(0.001);
        [probe pollInput];
    }
    if (probe.pending.length || QueryCancelled(probe) || MonotonicTime() >= deadline) return nil;
    uint8_t label = *transaction;
    *transaction = (label + 1) % 15;
    uint8_t header[] = {(uint8_t)(label << 4), signal};
    NSMutableData *request = [NSMutableData dataWithBytes:header length:sizeof(header)];
    [request appendData:payload];
    if (signal == 3) probe.configurationSent = YES;
    probe.framingUncertain = YES;
    if (!SendSignal(probe, request)) return nil;
    return AwaitResponse(probe, label, signal);
}

static BOOL EmptyAcceptance(NSData *reply) { return reply != nil && reply.length == 2; }

static BOOL WaitControl(DirectPlaybackProbe *probe, NSString *command) {
    BOOL closing = [command isEqualToString:@"media-closed"];
    NSTimeInterval timeout = [command isEqualToString:@"media-finished"] ? (probe.continuous ? INFINITY : 70) : closing ? 5 : 30;
    printf("WAIT_CONTROL %s deadline=%.0fs\n", command.UTF8String, timeout);
    double deadline = MIN(probe.hardDeadline, MonotonicTime() + timeout);
    while (MonotonicTime() < deadline) {
        if (probe.stdinEnded || (probe.stopRequested && !closing)) break;
        if (!probe.framingUncertain && !probe.failed && !probe.closed) {
            [probe pollInput];
            if (ServicePendingSignals(probe, 0, 0) < 0) break;
        }
        if (!closing && (probe.closed || probe.failed || probe.peerStopped)) break;
        NSString *line = ReadLine(probe, MIN(deadline, MonotonicTime() + 0.01), !closing, 0.001);
        if (!line) continue;
        if ([line isEqualToString:@"stop"]) continue;
        if ([line isEqualToString:@"media-failed"]) {
            printf("MEDIA_FAILED\n");
            return NO;
        }
        if ([command isEqualToString:@"media-ready"] && [line hasPrefix:@"media-ready "]) {
            unsigned int cid = 0, mtu = 0;
            char extra;
            if (sscanf(line.UTF8String, "media-ready %x %u %c", &cid, &mtu, &extra) != 2 ||
                !cid || cid > UINT16_MAX || cid == probe.realCID || mtu < 679 || mtu > UINT16_MAX) break;
            probe.mediaCID = (UInt16)cid;
            printf("MEDIA_READY CID=%04X outgoingMTU=%u\n", probe.mediaCID, mtu);
            return YES;
        }
        if ([line isEqualToString:command]) return YES;
        printf("UNEXPECTED_CONTROL expected=%s\n", command.UTF8String);
        break;
    }
    printf("CONTROL_FAILED expected=%s closed=%d\n", command.UTF8String, probe.closed);
    return NO;
}

static BOOL LDACSelection(NSData *reply, uint32_t sampleRate, BOOL *delayReporting) {
    const uint8_t *bytes = reply.bytes;
    BOOL ldac = NO;
    *delayReporting = NO;
    for (NSUInteger offset = 2; offset < reply.length;) {
        uint8_t category = bytes[offset++];
        uint8_t size = bytes[offset++];
        const uint8_t vendor[] = {0x00, 0xFF, 0x2D, 0x01, 0x00, 0x00, 0xAA, 0x00};
        if (category == 7 && size == 10 && memcmp(bytes + offset, vendor, sizeof(vendor)) == 0)
            ldac = !!((bytes[offset + 8] & RateBit(sampleRate)) && (bytes[offset + 9] & 1));
        if (category == 8 && size == 0) *delayReporting = YES;
        offset += size;
    }
    return ldac;
}

static BOOL PlaybackSequence(DirectPlaybackProbe *probe) {
    uint8_t transaction = 1;
    BOOL completed = NO;
    BOOL started = NO;
    do {
        NSData *discover = Query(probe, &transaction, 1, [NSData data]);
        NSArray<NSNumber *> *sinks = discover ? DecodeReply(discover, 1, 1, 0, YES) : nil;
        if (!sinks) break;
        BOOL capabilitiesComplete = YES;
        for (NSNumber *endpoint in sinks) {
            uint8_t seid = endpoint.unsignedCharValue;
            uint8_t encoded = seid << 2;
            uint8_t label = transaction;
            NSData *reply = Query(probe, &transaction, 12, [NSData dataWithBytes:&encoded length:1]);
            if (!reply || !DecodeReply(reply, label, 12, seid, YES)) {
                capabilitiesComplete = NO;
                break;
            }
            BOOL delayReporting = NO;
            if (!probe.selectedSink && LDACSelection(reply, probe.sampleRate, &delayReporting)) {
                probe.selectedSink = seid;
                probe.delayReporting = NO;
            }
        }
        if (!capabilitiesComplete || probe.peerStopped || probe.closed || probe.failed || probe.stopRequested) break;
        if (!probe.selectedSink) {
            printf("LDAC_UNAVAILABLE rate=%u channels=2\n", probe.sampleRate);
            break;
        }
        printf("PREPARE_MEDIA\n");
        if (!WaitControl(probe, @"media-prepared")) break;
        printf("LDAC_SELECTED remoteSEID=%u localSourceSEID=1 delayReporting=%d rate=%u channels=2 quality=%s\n",
               probe.selectedSink, probe.delayReporting, probe.sampleRate, probe.quality.UTF8String);
        uint8_t seids[] = {(uint8_t)(probe.selectedSink << 2), 0x04};
        NSMutableData *configuration = [NSMutableData dataWithBytes:seids length:2];
        [configuration appendData:ServiceBytes(probe.sampleRate, probe.delayReporting)];
        NSData *reply = Query(probe, &transaction, 3, configuration);
        if (!EmptyAcceptance(reply)) {
            if (probe.lastRejected) probe.configurationSent = NO;
            break;
        }
        probe.configured = YES;
        printf("CONFIGURATION_ACCEPTED remoteSEID=%u localSourceSEID=1 rate=%u channels=2\n", probe.selectedSink, probe.sampleRate);
        if (probe.stopRequested) break;
        NSData *target = [NSData dataWithBytes:seids length:1];
        NSData *readback = Query(probe, &transaction, 4, target);
        NSData *services = ServiceBytes(probe.sampleRate, probe.delayReporting);
        if (!readback || readback.length != services.length + 2 ||
            ![[readback subdataWithRange:NSMakeRange(2, services.length)] isEqualToData:services]) {
            printf("CONFIGURATION_VERIFICATION_FAILED\n");
            break;
        }
        printf("CONFIGURATION_VERIFIED rate=%u channels=2\n", probe.sampleRate);
        if (!EmptyAcceptance(Query(probe, &transaction, 6, target))) break;
        probe.streamOpened = YES;
        probe.mediaExpected = YES;
        printf("OPEN_ACCEPTED signalingCID=%04X remoteSEID=%u\n", probe.realCID, probe.selectedSink);
        if (probe.stopRequested) break;
        if (!WaitControl(probe, @"media-ready")) break;
        if (!EmptyAcceptance(Query(probe, &transaction, 7, target))) break;
        started = YES;
        printf("START_ACCEPTED signalingCID=%04X mediaCID=%04X\n", probe.realCID, probe.mediaCID);
        if (probe.stopRequested) break;
        if (!WaitControl(probe, @"media-finished")) break;
        if (!EmptyAcceptance(Query(probe, &transaction, 8, target))) break;
        probe.streamOpened = NO;
        probe.configured = NO;
        probe.configurationSent = NO;
        completed = YES;
        printf("STREAM_CLOSED peerSignal=00\n");
    } while (NO);
    if (!completed && !probe.closed && !probe.failed && !probe.peerStopped && probe.configurationSent) {
        uint8_t target = probe.selectedSink << 2;
        uint8_t signal = probe.framingUncertain ? 10 : probe.streamOpened || started ? 8 : 10;
        probe.protocolCleanup = YES;
        printf("ERROR_CLEANUP signal=%02X\n", signal);
        BOOL accepted = NO;
        if (probe.stdinEnded || probe.framingUncertain) {
            uint8_t request[] = {(uint8_t)(transaction << 4), signal, target};
            SendSignal(probe, [NSData dataWithBytes:request length:sizeof(request)]);
            printf("BEST_EFFORT_CLEANUP signal=%02X acceptance=unverified parentEOF=%d framing_uncertain=%d\n", signal, probe.stdinEnded, probe.framingUncertain);
        } else {
            accepted = EmptyAcceptance(Query(probe, &transaction, signal, [NSData dataWithBytes:&target length:1]));
        }
        if (accepted) {
            probe.configurationSent = NO;
            probe.configured = NO;
            probe.streamOpened = NO;
            printf("STREAM_CLOSED cleanupSignal=%02X\n", signal);
        }
    }
    if (probe.stopRequested && !probe.stdinEnded && !probe.failed && !probe.framingUncertain && !probe.configurationSent) {
        completed = YES;
        printf("STOP_COMPLETE protocolCleanup=1\n");
    }
    if (probe.mediaExpected) {
        printf("MEDIA_CLOSE_REQUIRED CID=%04X\n", probe.mediaCID);
        printf("WAIT_MEDIA_CLOSED\n");
        if (!WaitControl(probe, @"media-closed")) {
            completed = NO;
            if (probe.stdinEnded) {
                printf("MEDIA_CLOSE_UNCONFIRMED parentEOF=1 CID=%04X\n", probe.mediaCID);
                return NO;
            }
            printf("MEDIA_CLOSE_UNCONFIRMED deadline=1 CID=%04X\n", probe.mediaCID);
            return NO;
        }
        printf("MEDIA_CLOSED_CONFIRMED CID=%04X\n", probe.mediaCID);
    }
    return completed || (probe.mediaExpected && probe.peerStopped && !probe.failed && !probe.stdinEnded &&
                         !probe.configurationSent && !probe.pending.length);
}

static BOOL SelfTest(void) {
    const uint8_t discover[] = {0x12, 0x01, 0x04, 0x08, 0x08, 0x08, 0x0C, 0x08};
    const uint8_t caps[] = {0x22, 0x0C, 0x01, 0x00, 0x07, 0x0A, 0x00, 0xFF,
                           0x2D, 0x01, 0x00, 0x00, 0xAA, 0x00, 0x10, 0x01};
    NSData *endpoints = [NSData dataWithBytes:discover length:sizeof(discover)];
    NSData *capabilities = [NSData dataWithBytes:caps length:sizeof(caps)];
    BOOL passed = [DecodeReply(endpoints, 1, 1, 0, NO) isEqualToArray:@[@1, @2, @3]] &&
        DecodeReply(capabilities, 2, 12, 1, NO) != nil &&
        DecodeReply(endpoints, 2, 1, 0, NO) == nil &&
        DecodeReply(capabilities, 2, 2, 1, NO) == nil &&
        DecodeReply([endpoints subdataWithRange:NSMakeRange(0, endpoints.length - 1)], 1, 1, 0, NO) == nil &&
        DecodeReply([capabilities subdataWithRange:NSMakeRange(0, capabilities.length - 1)], 2, 12, 1, NO) == nil &&
        DecodeReply([endpoints subdataWithRange:NSMakeRange(0, 2)], 1, 1, 0, NO) == nil;
    DirectPlaybackProbe *probe = [DirectPlaybackProbe new];
    probe.sampleRate = 48000;
    probe.quality = @"low";
    const uint8_t command[] = {0x20, 0x01};
    const uint8_t freeSEP[] = {0x22, 0x01, 0x04, 0x00};
    const uint8_t usedSEP[] = {0x22, 0x01, 0x06, 0x00};
    NSData *request = [NSData dataWithBytes:command length:sizeof(command)];
    passed &= [PeerReply(probe, request) isEqualToData:[NSData dataWithBytes:freeSEP length:sizeof(freeSEP)]];
    probe.configured = YES;
    passed &= [PeerReply(probe, request) isEqualToData:[NSData dataWithBytes:usedSEP length:sizeof(usedSEP)]];
    const uint8_t delay[] = {0x30, 0x0D, 0x04, 0x00, 0x64};
    const uint8_t delayAccept[] = {0x32, 0x0D};
    passed &= [PeerReply(probe, [NSData dataWithBytes:delay length:sizeof(delay)])
        isEqualToData:[NSData dataWithBytes:delayAccept length:sizeof(delayAccept)]];
    probe.configured = NO;
    const uint8_t delayReject[] = {0x33, 0x0D, 0x31};
    passed &= [PeerReply(probe, [NSData dataWithBytes:delay length:sizeof(delay)])
        isEqualToData:[NSData dataWithBytes:delayReject length:sizeof(delayReject)]];
    probe.configured = YES;
    probe.configurationSent = YES;
    probe.streamOpened = YES;
    const uint8_t close[] = {0x40, 0x08, 0x04};
    const uint8_t closeAccept[] = {0x42, 0x08};
    passed &= [PeerReply(probe, [NSData dataWithBytes:close length:sizeof(close)])
        isEqualToData:[NSData dataWithBytes:closeAccept length:sizeof(closeAccept)]] &&
        probe.peerStopped && !probe.configured && !probe.configurationSent && !probe.streamOpened;
    const uint8_t actualCaps[] = {0x42, 0x0C, 0x01, 0x00, 0x07, 0x0A, 0x00, 0xFF, 0x2D,
                                 0x01, 0x00, 0x00, 0xAA, 0x00, 0x3C, 0x07, 0x04, 0x02,
                                 0x02, 0x00, 0x08, 0x00};
    NSData *actual = [NSData dataWithBytes:actualCaps length:sizeof(actualCaps)];
    const uint8_t sbcCaps[] = {0x22, 0x0C, 0x01, 0x00, 0x07, 0x06, 0x00, 0x00, 0x3F,
                              0xFF, 0x02, 0x23, 0x04, 0x02, 0x02, 0x00, 0x08, 0x00};
    const uint8_t aacCaps[] = {0x32, 0x0C, 0x01, 0x00, 0x07, 0x08, 0x00, 0x02, 0x80,
                              0x01, 0x8C, 0x82, 0xEE, 0x00, 0x04, 0x02, 0x02, 0x00, 0x08, 0x00};
    NSData *sbc = [NSData dataWithBytes:sbcCaps length:sizeof(sbcCaps)];
    NSData *aac = [NSData dataWithBytes:aacCaps length:sizeof(aacCaps)];
    passed &= DecodeReply(sbc, 2, 12, 1, NO) != nil && DecodeReply(aac, 3, 12, 2, NO) != nil;
    BOOL hasDelay = NO;
    passed &= DecodeReply(actual, 4, 12, 3, NO) != nil && LDACSelection(actual, 48000, &hasDelay) && hasDelay;
    const uint32_t rates[] = {44100, 48000, 88200, 96000};
    for (NSUInteger rate = 0; rate < 4; rate++) {
        probe.sampleRate = rates[rate];
        probe.configured = YES;
        passed &= LDACSelection(actual, rates[rate], &hasDelay) && hasDelay;
        passed &= LDACSelection(capabilities, rates[rate], &hasDelay) == (rates[rate] == 48000);
        passed &= !LDACSelection(sbc, rates[rate], &hasDelay) && !LDACSelection(aac, rates[rate], &hasDelay);
        const uint8_t signals[] = {2, 4, 12};
        for (NSUInteger index = 0; index < 3; index++) {
            uint8_t signal = signals[index];
            uint8_t query[] = {0x50, signal, 0x04};
            NSData *reply = PeerReply(probe, [NSData dataWithBytes:query length:sizeof(query)]);
            const uint8_t *bytes = reply.bytes;
            passed &= reply.length == (signal == 12 ? 18 : 16) && bytes[0] == 0x52 && bytes[1] == signal &&
                bytes[14] == RateBit(rates[rate]) && bytes[15] == 1 &&
                DecodeReply(reply, 5, signal, 1, NO) != nil;
            NSData *services = ServiceBytes(rates[rate], NO);
            passed &= [[reply subdataWithRange:NSMakeRange(2, services.length)] isEqualToData:services];
        }
    }
    uint32_t parsedRate = 0;
    passed &= ParseSampleRate("44100", &parsedRate) && parsedRate == 44100 &&
        !ParseSampleRate("96000x", &parsedRate) && !ParseSampleRate("32000", &parsedRate) &&
        !ParseSampleRate("4294967296", &parsedRate);
    passed &= !EmptyAcceptance(actual) && EmptyAcceptance([NSData dataWithBytes:closeAccept length:2]);

    return passed;
}

static BOOL RecordOpen(DirectPlaybackProbe *probe, CBL2CAPChannel *channel, NSInteger error) {
    if (!probe.openRequested || probe.openDone || (channel && channel.PSM != 0x19)) {
        probe.failed = YES;
        return NO;
    }
    probe.channel = channel;
    probe.realCID = channel.cid;
    probe.openError = error;
    probe.openDone = YES;
    probe.openIndeterminate = !channel && !error;
    if (probe.openIndeterminate) printf("OPEN_INDETERMINATE nil_channel=1 callback_status=0\n");
    BOOL opened = !error && channel && channel.cid && channel.outgoingMTU >= 2 && channel.inputStream && channel.outputStream;
    if (opened) printf("OWNED_OPEN CID=%04X outgoingMTU=%u\n", channel.cid, channel.outgoingMTU);
    return opened;
}

static BOOL RecordClosed(DirectPlaybackProbe *probe, CBL2CAPChannel *channel, NSInteger error) {
    BOOL matched = channel && channel == probe.channel && channel.PSM == 0x19 && channel.cid == probe.realCID;
    printf("CLOSE_CALLBACK status=%ld owned_match=%d\n", error, matched);
    if (matched && !probe.closed) {
        probe.closed = YES;
        printf("OWNED_CLOSED CID=%04X\n", probe.realCID);
    } else probe.failed = YES;
    return matched;
}

static BOOL WaitTransportClosed(DirectPlaybackProbe *probe) {
    double deadline = MIN(probe.hardDeadline, MonotonicTime() + 5);
    printf("WAIT_TRANSPORT_CLOSED CID=%04X\n", probe.realCID);
    while (!probe.closed && MonotonicTime() < deadline) {
        NSString *line = ReadLine(probe, MIN(deadline, MonotonicTime() + 0.01), NO, 0.001);
        if (line && ![line isEqualToString:@"stop"]) probe.failed = YES;
        [probe pollInput];
        RunLoopFor(0.001);
    }
    if (!probe.closed) {
        printf("TRANSPORT_CLOSE_UNCONFIRMED CID=%04X closeRequested=1\n", probe.realCID);
        probe.failed = YES;
    }
    return probe.closed;
}

static BOOL AcquisitionTrigger(NSString *line, uint64_t armed, uint64_t now) {
    uint64_t baseline = 0, connected = 0;
    int consumed = 0;
    if (sscanf(line.UTF8String, "acquire %" SCNu64 " %" SCNu64 "%n", &baseline, &connected, &consumed) != 2 ||
        line.UTF8String[consumed]) return NO;
    return baseline >= armed && connected > baseline && connected <= now && now - connected <= NSEC_PER_SEC;
}

static const char *RefreshOwnedPeer(CBClassicPeer *peer, CBClassicManager *manager) {
    if (peer.manager != manager || [manager peerWithIdentifier:peer.identifier] != peer) return "owned_peer_refresh_owner_mismatch";
    id reply = [peer sendInternalSyncMsg:0x2f args:nil];
    if (![reply isKindOfClass:NSDictionary.class]) return "owned_peer_refresh_invalid_reply";
    id state = reply[@"kCBMsgArgState"];
    if (![state isKindOfClass:NSDictionary.class]) return "owned_peer_refresh_invalid_reply";
    id number = state[@"kCBMsgArgInternalState"];
    if (![number isKindOfClass:NSNumber.class]) return "owned_peer_refresh_invalid_reply";
    if (![number isEqualToNumber:@2]) return "owned_peer_refresh_not_connected";
    if (peer.manager != manager || [manager peerWithIdentifier:peer.identifier] != peer) return "owned_peer_refresh_owner_mismatch";
    [peer handleGetPeerState:reply];
    if (peer.manager != manager || [manager peerWithIdentifier:peer.identifier] != peer) return "owned_peer_refresh_owner_mismatch";
    return peer.internalState == 2 ? NULL : "owned_peer_refresh_update_failed";
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "--self-test")) {
            BOOL passed = SelfTest();
            printf("offline parser checks=%s\n", passed ? "PASS" : "FAIL");
            return passed ? 0 : 1;
        }
        BOOL valid = argc >= 3 && !strcmp(argv[1], "--playback-disconnected");
        NSString *address = nil, *quality = @"low";
        uint32_t sampleRate = 48000;
        BOOL rateSeen = NO, qualitySeen = NO, continuousSeen = NO;
        for (int index = 3; valid && index < argc; index++) {
            if (!strcmp(argv[index], "--address") && !address && index + 1 < argc) {
                address = NormalizeAddress(argv[++index]);
                valid = address != nil;
            } else if (!strcmp(argv[index], "--sample-rate") && !rateSeen && index + 1 < argc) {
                rateSeen = YES;
                valid = ParseSampleRate(argv[++index], &sampleRate);
            } else if (!strcmp(argv[index], "--quality") && !qualitySeen && index + 1 < argc) {
                qualitySeen = YES;
                quality = [NSString stringWithUTF8String:argv[++index]];
                valid = [@[@"auto", @"low", @"mid", @"high"] containsObject:quality];
            } else if (!strcmp(argv[index], "--continuous") && !continuousSeen) continuousSeen = YES;
            else valid = NO;
        }
#if !ACOUPLET_LDAC_PROBE_ONLY
        valid &= continuousSeen;
#endif
        if (!valid || !address) {
#if ACOUPLET_LDAC_PROBE_ONLY
            fprintf(stderr, "Usage: %s --playback-disconnected received.bin --address XX-XX-XX-XX-XX-XX [--sample-rate 44100|48000|88200|96000] [--quality auto|low|mid|high] [--continuous]\n", argv[0]);
#else
            fprintf(stderr, "Usage: %s --playback-disconnected received.bin --address XX-XX-XX-XX-XX-XX --continuous [--sample-rate 44100|48000|88200|96000] [--quality auto|low|mid|high]\n", argv[0]);
#endif
            return 2;
        }
        if (!LDACWatchParent(20)) return 3;
        setbuf(stdout, NULL);
        signal(SIGINT, Stop);
        signal(SIGTERM, Stop);
        signal(SIGPIPE, SIG_IGN);
        if (!continuousSeen) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            const char message[] = "HARD_DEADLINE cleanup=unconfirmed\n";
            write(STDOUT_FILENO, message, sizeof(message) - 1);
            _exit(24);
        });
        IOBluetoothDevice *device = [IOBluetoothDevice deviceWithAddressString:address];
        if (!device || !device.isPaired) {
            printf("NO_OPEN reason=target_not_paired\n");
            return 3;
        }
        Class managerClass = NSClassFromString(@"CBClassicManager");
        for (NSString *selector in @[@"initWithQueue:options:", @"tccApproved", @"tccComplete", @"tccRequired", @"checkForTCC", @"retrievePeerWithAddress:", @"peerWithIdentifier:"]) {
            if (![managerClass instancesRespondToSelector:NSSelectorFromString(selector)]) {
                printf("NO_OPEN reason=classic_manager_interface_unavailable\n");
                return 4;
            }
        }
        CBClassicManager *manager __attribute__((objc_precise_lifetime)) =
            [[managerClass alloc] initWithQueue:dispatch_get_main_queue() options:nil];
        double deadline = MonotonicTime() + 5;
        BOOL authorizationRequested = NO;
        while (manager && !manager.tccApproved && !interrupted && MonotonicTime() < deadline) {
            if (manager.state == CBManagerStatePoweredOn && !manager.tccRequired && !manager.tccComplete && !authorizationRequested) {
                authorizationRequested = YES;
                [manager checkForTCC];
            }
            RunLoopFor(0.01);
        }
        if (!manager.tccApproved || interrupted) {
            printf("NO_OPEN reason=classic_manager_not_ready\n");
            return 4;
        }
        CBClassicPeer *peer __attribute__((objc_precise_lifetime)) =
            [manager retrievePeerWithAddress:[address stringByReplacingOccurrencesOfString:@"-" withString:@":"]];
        for (NSString *selector in @[@"internalState", @"manager", @"sendInternalSyncMsg:args:", @"handleGetPeerState:",
            @"connectL2CAPCallback", @"disconnectL2CAPCallback", @"setConnectL2CAPCallback:", @"setDisconnectL2CAPCallback:",
            @"openL2CAPChannel:", @"closeL2CAPChannel:"]) {
            if (![peer respondsToSelector:NSSelectorFromString(selector)]) {
                printf("NO_OPEN reason=classic_peer_interface_unavailable\n");
                return 4;
            }
        }
        Method refreshQuery = class_getInstanceMethod(peer.class, @selector(sendInternalSyncMsg:args:));
        Method refreshHandler = class_getInstanceMethod(peer.class, @selector(handleGetPeerState:));
        if (!refreshQuery || strcmp(method_getTypeEncoding(refreshQuery), "@28@0:8i16@20") ||
            !refreshHandler || strcmp(method_getTypeEncoding(refreshHandler), "v24@0:8@16")) {
            printf("NO_OPEN reason=unexpected_peer_refresh_abi\n");
            return 4;
        }
        if (peer.manager != manager || [manager peerWithIdentifier:peer.identifier] != peer ||
            peer.connectL2CAPCallback || peer.disconnectL2CAPCallback) {
            printf("NO_OPEN reason=classic_peer_not_owned\n");
            return 4;
        }
        DirectPlaybackProbe *probe __attribute__((objc_precise_lifetime)) = [DirectPlaybackProbe new];
        probe.pending = [NSMutableData data];
        probe.raw = [NSMutableData data];
        probe.controlPending = [NSMutableData data];
        probe.sampleRate = sampleRate;
        probe.quality = quality;
        probe.continuous = continuousSeen;
        probe.hardDeadline = continuousSeen ? INFINITY : MonotonicTime() + 140;
        void (^ownedOpen)(CBL2CAPChannel *, NSInteger) = [^(CBL2CAPChannel *value, NSInteger error) {
            dispatch_async(dispatch_get_main_queue(), ^{ RecordOpen(probe, value, error); });
        } copy];
        void (^ownedClose)(CBL2CAPChannel *, NSInteger) = [^(CBL2CAPChannel *value, NSInteger error) {
            dispatch_async(dispatch_get_main_queue(), ^{ RecordClosed(probe, value, error); });
        } copy];
        peer.connectL2CAPCallback = ownedOpen;
        peer.disconnectL2CAPCallback = ownedClose;
        probe.callbacksIntact = ^BOOL {
            BOOL intact = peer.manager == manager && [manager peerWithIdentifier:peer.identifier] == peer &&
                peer.connectL2CAPCallback == ownedOpen && peer.disconnectL2CAPCallback == ownedClose;
            if (!intact) printf("OWNED_CALLBACKS_LOST cleanup=unconfirmed\n");
            return intact;
        };
        uint64_t armed = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        printf("SIGNALING_ARMED time_ns=%" PRIu64 "\n", armed);
        NSString *acquire = ReadLine(probe, MonotonicTime() + 50, YES, 0.001);
        BOOL triggered = acquire && AcquisitionTrigger(acquire, armed, clock_gettime_nsec_np(CLOCK_MONOTONIC));
        const char *refreshFailure = triggered ? RefreshOwnedPeer(peer, manager) : "missing_or_invalid_fresh_acl_trigger";
        int result = 5;
        if (refreshFailure || probe.stopRequested || probe.failed || probe.stdinEnded) {
            printf("NO_OPEN reason=%s\n", refreshFailure ?: "canceled_or_owner_unavailable");
            if (probe.stopRequested && !probe.failed && !probe.stdinEnded) result = 0;
        } else {
            probe.openRequested = YES;
            printf("OPEN_BEGIN PSM=0019\n");
            [peer openL2CAPChannel:0x19];
            deadline = MonotonicTime() + 5;
            while (!probe.openDone && !probe.stopRequested && !probe.failed && MonotonicTime() < deadline) {
                NSString *line = ReadLine(probe, MIN(deadline, MonotonicTime() + 0.01), NO, 0.001);
                if (line && ![line isEqualToString:@"stop"]) probe.failed = YES;
            }
            BOOL expired = !probe.openDone;
            if (expired) {
                printf("OPEN_PENDING cancel_or_deadline=1 retaining_owner=1\n");
                deadline = MonotonicTime() + 5;
                while (!probe.openDone && MonotonicTime() < deadline) {
                    ReadLine(probe, MIN(deadline, MonotonicTime() + 0.01), NO, 0.001);
                    RunLoopFor(0.001);
                }
            }
            CBL2CAPChannel *channel = probe.channel;
            if (!expired && !probe.openError && channel && channel.PSM == 0x19 && probe.realCID &&
                channel.outgoingMTU >= 2 && channel.inputStream && channel.outputStream &&
                !probe.closed && !probe.failed && !probe.stopRequested) {
                probe.input = channel.inputStream;
                probe.output = channel.outputStream;
                [probe.input open];
                [probe.output open];
                printf("SIGNAL_WRITER fd=%d MTU=%u mode=public-stream\n", channel.socketFD, channel.outgoingMTU);
                result = PlaybackSequence(probe) ? 0 : 5;
            }
            if (channel && !probe.closed) {
                probe.closing = YES;
                [peer closeL2CAPChannel:0x19];
                if (!WaitTransportClosed(probe)) result = 5;
            }
            if (!probe.openDone || probe.openIndeterminate) {
                printf("OPEN_CLEANUP_UNCONFIRMED pending=%d indeterminate=%d\n", !probe.openDone, probe.openIndeterminate);
                result = 5;
            }
        }
        [probe.input close];
        [probe.output close];
        probe.callbacksIntact = nil;
        if (peer.connectL2CAPCallback == ownedOpen) peer.connectL2CAPCallback = nil;
        if (peer.disconnectL2CAPCallback == ownedClose) peer.disconnectL2CAPCallback = nil;
        NSError *error = nil;
        BOOL saved = [probe.raw writeToFile:[NSString stringWithUTF8String:argv[2]] options:NSDataWritingAtomic error:&error];
        if (!saved || probe.failed || probe.pending.length || probe.framingUncertain) result = 5;
        printf("SIGNALING_COMPLETE result=%d raw_bytes=%lu received_bytes=%lu pending_bytes=%lu framing_uncertain=%d owned_closed=%d saved=%d\n",
               result, probe.raw.length, probe.received, probe.pending.length, probe.framingUncertain, probe.closed, saved);
        return result;
    }
}
