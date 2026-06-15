#pragma once

#import <Foundation/Foundation.h>

// ===========================================================================
// logging.h — NSLog + os_log + sandbox file log destination.
//
// Implementation in logging.m. Each tweak picks its own os_log subsystem at
// init so console output stays distinguishable when several tweaks are
// loaded into the same process. Typical subsystem strings follow
// reverse-DNS:
//
//   "com.example.tweak.foo"
//   "com.example.tweak.bar"
//
// logging.m derives a short tag from the subsystem (the last dot-separated
// segment) and prepends it to each NSLog line.
//
// File log destination: NSTemporaryDirectory() + "<tag>.log", where the tag
// comes from the short segment derived above. This is the app sandbox's
// tmp/ directory — readable from host via
// `/var/mobile/Containers/Data/Application/<UUID>/tmp/<tag>.log`.
//
// Why no root-accessible destination: rootless tweaks run as the host app
// (`mobile`), which can't write to `/var/tmp/`. Earlier revisions of this
// API took a second `logFile` argument meant as a root-readable mirror;
// under rootless that write always failed (silently swallowed), so the API
// has been simplified to drop it.
//
// When IPA_LOG_TO_DOCUMENTS=1 is defined at build time (typical for the
// statically-patched / sideload-injected distribution flavor), the file
// destination is moved to <sandbox>/Documents/<tag>.log instead. That
// directory is exposed through Files.app once the host app's Info.plist
// carries UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace, so
// non-jailbroken operators can read the log over the Files app.
//
// Calls before logging_init() fall back to NSLog only; the file/os_log
// destinations come up once logging_init() has run.
// ===========================================================================

void file_log(NSString *msg);
void logging_init(const char *subsystem);
