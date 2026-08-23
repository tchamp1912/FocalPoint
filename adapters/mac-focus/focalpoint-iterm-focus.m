#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <ScriptingBridge/ScriptingBridge.h>
#import <time.h>

// Exact iTerm endpoint lookup/focus for installations with more than one
// iTerm2 application process. AppleScript addressed by bundle id talks to
// only one process, so it cannot reliably see a session owned by a legacy
// `open -n` instance. ScriptingBridge can target one specific PID.

static NSArray *FPArrayValue(id object, NSString *key) {
    @try {
        id value = [object valueForKey:key];
        return [value isKindOfClass:[NSArray class]] ? value : @[];
    } @catch (__unused NSException *exception) {
        return @[];
    }
}

static NSString *FPStringValue(id object, NSString *key) {
    @try {
        id value = [object valueForKey:key];
        return [value isKindOfClass:[NSString class]] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void FPSelect(id object) {
    SEL selector = NSSelectorFromString(@"select");
    if ([object respondsToSelector:selector]) {
        IMP implementation = [object methodForSelector:selector];
        void (*invoke)(id, SEL) = (void *)implementation;
        invoke(object, selector);
    }
}

static BOOL FPClose(id object) {
    SEL selector = NSSelectorFromString(@"close");
    if (![object respondsToSelector:selector]) return NO;
    IMP implementation = [object methodForSelector:selector];
    void (*invoke)(id, SEL) = (void *)implementation;
    invoke(object, selector);
    return YES;
}

static void FPUsage(void) {
    fprintf(stderr,
            "usage: focalpoint-iterm-focus (--lookup|--focus|--close) "
            "(--session-id ID|--tty TTY) [--application-pid PID]\n");
}

static uint64_t FPMonotonicNanoseconds(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC_RAW, &value);
    return (uint64_t)value.tv_sec * 1000000000ULL + (uint64_t)value.tv_nsec;
}

static double FPMillisecondsSince(uint64_t start) {
    return (double)(FPMonotonicNanoseconds() - start) / 1000000.0;
}

static BOOL FPTimingEnabled(void) {
    const char *value = getenv("FOCALPOINT_FOCUS_TIMING");
    return value != NULL && strcmp(value, "1") == 0;
}

static void FPLogTiming(uint64_t totalStart, double applicationsMilliseconds,
                        double activationMilliseconds, NSUInteger applicationCount,
                        NSUInteger windowCount, NSUInteger tabCount,
                        NSUInteger sessionCount, BOOL matched) {
    if (!FPTimingEnabled()) return;
    fprintf(stderr,
            "[focus-timing] adapter=iterm-helper result=%s total_ms=%.3f "
            "applications_ms=%.3f activation_ms=%.3f applications=%lu "
            "windows=%lu tabs=%lu sessions=%lu\n",
            matched ? "matched" : "missed", FPMillisecondsSince(totalStart),
            applicationsMilliseconds, activationMilliseconds,
            (unsigned long)applicationCount, (unsigned long)windowCount,
            (unsigned long)tabCount, (unsigned long)sessionCount);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        uint64_t totalStart = FPMonotonicNanoseconds();
        BOOL focus = NO;
        BOOL lookup = NO;
        BOOL close = NO;
        NSString *sessionID = nil;
        NSString *tty = nil;
        pid_t requiredPID = 0;

        for (int index = 1; index < argc; index++) {
            NSString *argument = [NSString stringWithUTF8String:argv[index]];
            if ([argument isEqualToString:@"--focus"]) {
                focus = YES;
            } else if ([argument isEqualToString:@"--lookup"]) {
                lookup = YES;
            } else if ([argument isEqualToString:@"--close"]) {
                close = YES;
            } else if ([argument isEqualToString:@"--session-id"] && index + 1 < argc) {
                sessionID = [NSString stringWithUTF8String:argv[++index]];
            } else if ([argument isEqualToString:@"--tty"] && index + 1 < argc) {
                tty = [NSString stringWithUTF8String:argv[++index]];
            } else if ([argument isEqualToString:@"--application-pid"] && index + 1 < argc) {
                long long parsed = strtoll(argv[++index], NULL, 10);
                if (parsed <= 1 || parsed > INT_MAX) {
                    FPUsage();
                    return 64;
                }
                requiredPID = (pid_t)parsed;
            } else {
                FPUsage();
                return 64;
            }
        }

        if ((focus + lookup + close) != 1 || ((sessionID != nil) == (tty != nil))) {
            FPUsage();
            return 64;
        }

        uint64_t applicationsStart = FPMonotonicNanoseconds();
        NSArray<NSRunningApplication *> *applications =
            [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.googlecode.iterm2"];
        applications = [applications sortedArrayUsingComparator:^NSComparisonResult(
            NSRunningApplication *left, NSRunningApplication *right) {
            if (left.processIdentifier < right.processIdentifier) return NSOrderedAscending;
            if (left.processIdentifier > right.processIdentifier) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        double applicationsMilliseconds = FPMillisecondsSince(applicationsStart);
        NSUInteger windowCount = 0;
        NSUInteger tabCount = 0;
        NSUInteger sessionCount = 0;

        for (NSRunningApplication *running in applications) {
            pid_t pid = running.processIdentifier;
            if (requiredPID != 0 && pid != requiredPID) continue;

            SBApplication *application = [SBApplication applicationWithProcessIdentifier:pid];
            if (application == nil || !application.running) continue;
            // Apple Event timeout units are ticks (60 per second). Keep a
            // dead legacy instance from making a keyboard shortcut hang.
            application.timeout = 60;

            for (id window in FPArrayValue(application, @"windows")) {
                windowCount++;
                for (id tab in FPArrayValue(window, @"tabs")) {
                    tabCount++;
                    for (id session in FPArrayValue(tab, @"sessions")) {
                        sessionCount++;
                        NSString *observedSessionID = FPStringValue(session, @"uniqueID");
                        NSString *observedTTY = FPStringValue(session, @"tty");
                        BOOL matched = sessionID != nil
                            ? [observedSessionID isEqualToString:sessionID]
                            : [observedTTY isEqualToString:tty];
                        if (!matched) continue;

                        uint64_t activationStart = FPMonotonicNanoseconds();
                        if (focus) {
                            FPSelect(session);
                            FPSelect(tab);
                            FPSelect(window);
                            [running activateWithOptions:0];
                        } else if (close) {
                            if (!FPClose(session)) return 3;
                        }
                        double activationMilliseconds = FPMillisecondsSince(activationStart);
                        printf("%d|%s|%s\n", pid,
                               observedSessionID.UTF8String ?: "",
                               observedTTY.UTF8String ?: "");
                        FPLogTiming(totalStart, applicationsMilliseconds,
                                    activationMilliseconds, applications.count,
                                    windowCount, tabCount, sessionCount, YES);
                        return 0;
                    }
                }
            }
        }

        FPLogTiming(totalStart, applicationsMilliseconds, 0.0,
                    applications.count, windowCount, tabCount, sessionCount, NO);
        return 2;
    }
}
