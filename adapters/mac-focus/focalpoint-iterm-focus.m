#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <ScriptingBridge/ScriptingBridge.h>

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

static void FPUsage(void) {
    fprintf(stderr,
            "usage: focalpoint-iterm-focus (--lookup|--focus) "
            "(--session-id ID|--tty TTY) [--application-pid PID]\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL focus = NO;
        BOOL lookup = NO;
        NSString *sessionID = nil;
        NSString *tty = nil;
        pid_t requiredPID = 0;

        for (int index = 1; index < argc; index++) {
            NSString *argument = [NSString stringWithUTF8String:argv[index]];
            if ([argument isEqualToString:@"--focus"]) {
                focus = YES;
            } else if ([argument isEqualToString:@"--lookup"]) {
                lookup = YES;
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

        if (focus == lookup || ((sessionID != nil) == (tty != nil))) {
            FPUsage();
            return 64;
        }

        NSArray<NSRunningApplication *> *applications =
            [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.googlecode.iterm2"];
        applications = [applications sortedArrayUsingComparator:^NSComparisonResult(
            NSRunningApplication *left, NSRunningApplication *right) {
            if (left.processIdentifier < right.processIdentifier) return NSOrderedAscending;
            if (left.processIdentifier > right.processIdentifier) return NSOrderedDescending;
            return NSOrderedSame;
        }];

        for (NSRunningApplication *running in applications) {
            pid_t pid = running.processIdentifier;
            if (requiredPID != 0 && pid != requiredPID) continue;

            SBApplication *application = [SBApplication applicationWithProcessIdentifier:pid];
            if (application == nil || !application.running) continue;
            // Apple Event timeout units are ticks (60 per second). Keep a
            // dead legacy instance from making a keyboard shortcut hang.
            application.timeout = 60;

            for (id window in FPArrayValue(application, @"windows")) {
                for (id tab in FPArrayValue(window, @"tabs")) {
                    for (id session in FPArrayValue(tab, @"sessions")) {
                        NSString *observedSessionID = FPStringValue(session, @"uniqueID");
                        NSString *observedTTY = FPStringValue(session, @"tty");
                        BOOL matched = sessionID != nil
                            ? [observedSessionID isEqualToString:sessionID]
                            : [observedTTY isEqualToString:tty];
                        if (!matched) continue;

                        if (focus) {
                            FPSelect(session);
                            FPSelect(tab);
                            FPSelect(window);
                            [running activateWithOptions:0];
                        }
                        printf("%d|%s|%s\n", pid,
                               observedSessionID.UTF8String ?: "",
                               observedTTY.UTF8String ?: "");
                        return 0;
                    }
                }
            }
        }

        return 2;
    }
}
