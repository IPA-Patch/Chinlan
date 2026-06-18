#pragma once

#import <Foundation/Foundation.h>
#include <stdint.h>

#ifndef FINAL_RELEASE

// ===========================================================================
// logserver.h — debug-only TCP log streaming server (Chinlan layer).
//
// Automatically started by IPALoggingInit() on the default port when
// FINAL_RELEASE is not defined. Every IPALog() call is forwarded to all
// connected clients, so logs can be tailed from any terminal with:
//
//   nc <device-ip> 18082
//
// No SSH, no Files.app, no jailbreak required — works on any Jailed build
// from a PC on the same network.
// Up to IPA_LOG_SERVER_MAX_CLIENTS simultaneous readers are supported;
// a new connection beyond that cap is silently dropped.
//
// Compile-time behaviour:
//   FINAL_RELEASE undefined  →  server starts, push is live
//   FINAL_RELEASE=1          →  this header is empty; logserver.m compiles
//                               to nothing; zero overhead in the binary
//
// Called by logging.m; consumers do not call these directly.
// ===========================================================================

#define IPA_LOG_SERVER_DEFAULT_PORT 18082
#define IPA_LOG_SERVER_MAX_CLIENTS  4

// Start listening on 0.0.0.0:<port>. Safe to call multiple times;
// subsequent calls after the first are silent no-ops.
void IPALogServerStart(uint16_t port);

// Broadcast a log line to all connected clients. Called from IPALog().
// line must be non-nil; the implementation appends a trailing newline if
// absent. Returns immediately when no clients are connected.
void IPALogServerPush(NSString *line);

#endif  // !FINAL_RELEASE
