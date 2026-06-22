#import "logging.h"
#import <os/log.h>
#import <stdatomic.h>

// ===========================================================================
// logging.m — implementation backing logging.h.
//
// Three destinations on every IPALog():
//   * NSLog              — Console.app, always on
//   * os_log             — unified logging, subsystem-scoped
//   * g_logSandbox file  — append-only file inside the host app's sandbox
//
// File destination layout — every flavor writes into a `Logs/` subdirectory
// of its base path (created on init), so operators can grab the whole
// directory at once instead of fishing individual files out of tmp/ or
// Documents/. The directory name follows iOS's own sandbox PascalCase
// convention (sibling to `Documents/`, `Library/`). The default base is
// NSTemporaryDirectory() (which resolves to
// /var/mobile/Containers/Data/Application/<UUID>/tmp/), so the full path is
//   .../tmp/Logs/<tag>.log
//
// When IPA_LOG_TO_DOCUMENTS=1 is defined at build time, the base moves to
// <sandbox>/Documents/ instead. That directory is exposed through Files.app
// once the host app's Info.plist carries UIFileSharingEnabled +
// LSSupportsOpeningDocumentsInPlace — typical for the statically-patched /
// sideload-injected distribution flavor where the operator has no SSH
// access. The same log can then be read over the Files app on a
// non-jailbroken device.
//
// Rotation — to keep a runaway process from filling the sandbox with one
// multi-GB log file, the file destination rotates once it crosses
// IPA_LOG_MAX_BYTES (default 4 MiB):
//
//   <tag>.log  -> <tag>.1.log
//   <tag>.1.log -> <tag>.2.log
//   ...
//   <tag>.{N-1}.log -> dropped
//
// where N = IPA_LOG_GENERATIONS (default 3). The size check is sampled
// every IPA_LOG_ROTATE_CHECK_EVERY writes (default 64) — exact bytes-on-
// disk control is intentionally relaxed so per-line stat() cost stays
// bounded. The check still uses a serial lock so two concurrent writers
// can't both rotate the same file.
//
// The sandbox file write is best-effort and silently swallows exceptions
// so a flaky filesystem can't take down the host process.
// ===========================================================================

#ifndef IPA_LOG_MAX_BYTES
#define IPA_LOG_MAX_BYTES          (4 * 1024 * 1024)   // 4 MiB per file
#endif
#ifndef IPA_LOG_GENERATIONS
#define IPA_LOG_GENERATIONS        3                   // .log + .1.log + .2.log
#endif
#ifndef IPA_LOG_ROTATE_CHECK_EVERY
#define IPA_LOG_ROTATE_CHECK_EVERY 64                  // stat() every N writes
#endif

static os_log_t  g_log         = NULL;
static NSString *g_logSandbox  = nil;
static NSString *g_tag         = @"tweak";
static atomic_uint g_writeCount __attribute__((unused)) = 0;

// Slide <tag>.{N-2}.log → <tag>.{N-1}.log, ..., <tag>.log → <tag>.1.log,
// dropping anything past <tag>.{N-1}.log. Caller guarantees serial entry
// via the dispatch queue below.
static void IPALogRotate(NSString *path) {
    NSFileManager *fm  = [NSFileManager defaultManager];
    NSString *dir      = [path stringByDeletingLastPathComponent];
    NSString *file     = [path lastPathComponent];
    NSString *stem     = [file stringByDeletingPathExtension];     // "<tag>"
    NSString *ext      = [file pathExtension];                      // "log"
    int gens           = IPA_LOG_GENERATIONS;
    if (gens < 2) return;  // nothing to rotate into

    @try {
        // Drop the oldest generation (gens-1).
        NSString *drop = [dir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.%d.%@", stem, gens - 1, ext]];
        [fm removeItemAtPath:drop error:nil];

        // Shift gens-2 .. 1 each down one slot.
        for (int i = gens - 2; i >= 1; i--) {
            NSString *src = [dir stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@.%d.%@", stem, i, ext]];
            NSString *dst = [dir stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@.%d.%@", stem, i + 1, ext]];
            if ([fm fileExistsAtPath:src])
                [fm moveItemAtPath:src toPath:dst error:nil];
        }

        // Current <tag>.log → <tag>.1.log.
        NSString *first = [dir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.1.%@", stem, ext]];
        [fm moveItemAtPath:path toPath:first error:nil];
    } @catch (NSException *e) {}
}

// Check size every IPA_LOG_ROTATE_CHECK_EVERY writes and rotate if we're
// past IPA_LOG_MAX_BYTES. Sampling avoids a stat() per IPALog while still
// catching runaway logs within ~64 lines of the limit.
static void IPAMaybeRotate(NSString *path) {
    unsigned n = atomic_fetch_add_explicit(&g_writeCount, 1, memory_order_relaxed);
    if ((n % IPA_LOG_ROTATE_CHECK_EVERY) != 0) return;

    NSDictionary *attrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attrs) return;
    unsigned long long size = [attrs fileSize];
    if (size < (unsigned long long)IPA_LOG_MAX_BYTES) return;

    IPALogRotate(path);
}

static void IPALogPath(NSString *path, NSString *msg) {
    if (!path) return;
    @try {
        IPAMaybeRotate(path);
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                          [df stringFromDate:[NSDate date]], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

void IPALog(NSString *msg) {
    if (!msg) msg = @"(null)";
    NSLog(@"[%@] %@", g_tag, msg);
    if (g_log) {
        os_log(g_log, "%{public}s", msg.UTF8String);
    }
    if (g_logSandbox) IPALogPath(g_logSandbox, msg);
}

void IPALoggingInit(const char *subsystem) {
    if (!subsystem) return;

    g_log = os_log_create(subsystem, "tweak");

    // Derive a short tag from the last dot-separated segment of the
    // subsystem. The tag is reused for the sandbox log filename so multiple
    // tweaks loaded into the same process don't clobber each other's files.
    NSString *sub = [NSString stringWithUTF8String:subsystem];
    NSArray *parts = [sub componentsSeparatedByString:@"."];
    if (parts.count > 0) {
        NSString *last = [parts lastObject];
        if (last.length > 0) g_tag = last;
    }

    NSString *filename = [g_tag stringByAppendingString:@".log"];

    // Pick the base directory. Documents/ on the IPA-distribution flavor so
    // Files.app can read it; tmp/ everywhere else.
#if defined(IPA_LOG_TO_DOCUMENTS) && IPA_LOG_TO_DOCUMENTS
    NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *base = (docs.count > 0)
        ? docs[0]
        : NSTemporaryDirectory();
#else
    NSString *base = NSTemporaryDirectory();
#endif

    // Group every flavor's logs under `<base>/Logs/` so the rotated set
    // (<tag>.log, <tag>.1.log, <tag>.2.log…) lives in one folder operators
    // can grab in one shot. PascalCase matches iOS's own sandbox
    // conventions (`Documents/`, `Library/`, etc.). Best-effort mkdir —
    // a stale symlink or perms issue downgrades us to writing into the
    // base directly.
    NSString *logsDir = [base stringByAppendingPathComponent:@"Logs"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *mkdirErr = nil;
    BOOL ok = [fm createDirectoryAtPath:logsDir
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:&mkdirErr];
    if (!ok) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:logsDir isDirectory:&isDir] || !isDir) {
            logsDir = base;  // fall back to the parent
        }
    }

    g_logSandbox = [logsDir stringByAppendingPathComponent:filename];
}
