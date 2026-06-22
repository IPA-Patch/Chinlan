#import "logserver.h"

#ifndef FINAL_RELEASE

#import "logging.h"

#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <stdatomic.h>
#import <sys/socket.h>
#import <unistd.h>

// ===========================================================================
// logserver.m — debug-only TCP log streaming server.
//
// Architecture mirrors Server_CSA.m but fans out to up to
// IPA_LOG_SERVER_MAX_CLIENTS simultaneous clients instead of one. The
// tradeoff vs. CSA's single-client design is intentional: for log reading
// you often want two terminals open at once (one raw, one grepped).
//
// Transport:
//   - Binds to 0.0.0.0 so operators can tail from a PC on the same LAN.
//   - Debug-build only; FINAL_RELEASE compiles this file down to nothing.
//   - Line-oriented UTF-8. Each IPALogServerPush() sends one LF-terminated
//     line to every client whose fd is live.
//   - A new client beyond MAX_CLIENTS is closed immediately; the caller
//     is never blocked.
//   - Dead clients are detected on send failure and evicted inline.
//   - A soft queue-depth cap (LOG_SERVER_QUEUE_DEPTH_MAX) prevents a
//     slow reader from building up unbounded backlog; lines are dropped
//     with a counter rather than blocking the IPALog() call chain.
//
// All operations that touch g_clients[] run on g_queue (serial), so no
// locking primitives beyond the atomic client-count are needed.
// ===========================================================================

#define LOG_SERVER_RECV_CHUNK       256
#define LOG_SERVER_QUEUE_DEPTH_MAX  256

// How many bytes from the end of the log file to replay to a new client.
// Aligned up to the next newline boundary so no partial lines are sent.
#ifndef IPA_LOG_REPLAY_BYTES
#define IPA_LOG_REPLAY_BYTES (100 * 1024)
#endif

// ---------------------------------------------------------------------------
// Module state.
// ---------------------------------------------------------------------------
static dispatch_queue_t  g_queue     = NULL;
static dispatch_source_t g_listenSrc = NULL;
static int               g_listenFd  = -1;

// Client fd array and atomic drop counter, both accessed on g_queue.
static int               g_clients[IPA_LOG_SERVER_MAX_CLIENTS];
static int               g_clientCount = 0;
static _Atomic uint32_t  g_dropped     = 0;
static _Atomic uint32_t  g_pending     = 0;

// Log file path for replay-on-connect. Set via IPALogServerSetReplayPath().
// Accessed on g_queue only.
static NSString         *g_replayPath  = nil;

// ---------------------------------------------------------------------------
// Socket helpers.
// ---------------------------------------------------------------------------
static void ls_set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void ls_set_keepalive(int fd) {
    int on = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, sizeof(on));
    int idle = 5, intvl = 3, count = 3;
    (void)setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle,  sizeof(idle));
    (void)setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
    (void)setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT,   &count, sizeof(count));
}

// Send all bytes to fd. Returns NO and closes fd on any error.
static BOOL ls_send_all(int fd, const uint8_t *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = send(fd, buf + off, len - off, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (n == 0) return NO;
        off += (size_t)n;
    }
    return YES;
}

// ---------------------------------------------------------------------------
// Replay history — send the tail of the log file to a freshly connected
// client, then return so the caller can add it to the live-stream set.
// Runs on g_queue so g_replayPath access is safe.
// ---------------------------------------------------------------------------
static void ls_replay_to(int fd) {
    if (!g_replayPath) return;

    int fileFd = open(g_replayPath.UTF8String, O_RDONLY | O_NONBLOCK);
    if (fileFd < 0) return;

    off_t fileSize = lseek(fileFd, 0, SEEK_END);
    if (fileSize <= 0) { close(fileFd); return; }

    // Start IPA_LOG_REPLAY_BYTES before EOF (or at BOF if file is smaller).
    off_t startOff = (fileSize > (off_t)IPA_LOG_REPLAY_BYTES)
        ? fileSize - (off_t)IPA_LOG_REPLAY_BYTES
        : 0;

    if (lseek(fileFd, startOff, SEEK_SET) < 0) { close(fileFd); return; }

    // Skip forward to the next newline so we don't send a partial first line.
    if (startOff > 0) {
        char ch;
        while (read(fileFd, &ch, 1) == 1 && ch != '\n') {}
    }

    // Stream the rest to the client in chunks.
    uint8_t buf[4096];
    ssize_t n;
    while ((n = read(fileFd, buf, sizeof(buf))) > 0) {
        const uint8_t *p = buf;
        size_t rem = (size_t)n;
        while (rem > 0) {
            ssize_t sent = send(fd, p, rem, 0);
            if (sent <= 0) { close(fileFd); return; }
            p   += sent;
            rem -= (size_t)sent;
        }
    }
    close(fileFd);
}

// ---------------------------------------------------------------------------
// Client management — must be called on g_queue.
// ---------------------------------------------------------------------------
static void ls_add_client(int fd) {
    if (g_clientCount >= IPA_LOG_SERVER_MAX_CLIENTS) {
        IPALog([NSString stringWithFormat:
                  @"[LOGSVR] max clients (%d) reached, dropping fd=%d",
                  IPA_LOG_SERVER_MAX_CLIENTS, fd]);
        close(fd);
        return;
    }
    // Replay history before admitting to the live stream so the client sees
    // events that happened before it connected.
    ls_replay_to(fd);
    g_clients[g_clientCount++] = fd;
    IPALog([NSString stringWithFormat:
              @"[LOGSVR] client connected fd=%d (%d/%d)",
              fd, g_clientCount, IPA_LOG_SERVER_MAX_CLIENTS]);
}

// Evict the client at index i, compacting the array. Called on g_queue.
static void ls_evict_at(int i) {
    int fd = g_clients[i];
    close(fd);
    IPALog([NSString stringWithFormat:@"[LOGSVR] client disconnected fd=%d", fd]);
    // Compact: move the last entry into the vacated slot.
    g_clients[i] = g_clients[--g_clientCount];
}

// ---------------------------------------------------------------------------
// Drain inbound bytes from a client. We don't speak any protocol so we
// discard everything, but we need to detect EOF/RST to evict the client.
// Returns NO if the client has gone away.
// ---------------------------------------------------------------------------
static BOOL ls_drain_client(int fd) {
    uint8_t buf[LOG_SERVER_RECV_CHUNK];
    ssize_t n = recv(fd, buf, sizeof(buf), MSG_DONTWAIT);
    if (n > 0) return YES;           // data discarded
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return YES;
    return NO;                        // EOF or error — evict
}

// ---------------------------------------------------------------------------
// accept() handler — fires on g_queue via dispatch source.
// ---------------------------------------------------------------------------
static void ls_handle_accept(void) {
    struct sockaddr_in peer;
    socklen_t peerLen = sizeof(peer);
    int fd = accept(g_listenFd, (struct sockaddr *)&peer, &peerLen);
    if (fd < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            IPALog([NSString stringWithFormat:
                      @"[LOGSVR] accept errno=%d", errno]);
        }
        return;
    }

    // Flip to non-blocking so push doesn't stall on a slow reader.
    ls_set_nonblock(fd);
    ls_set_keepalive(fd);
    ls_add_client(fd);
}

// ---------------------------------------------------------------------------
// Public API.
// ---------------------------------------------------------------------------
void IPALogServerSetReplayPath(NSString *path) {
    if (!g_queue) return;
    dispatch_async(g_queue, ^{ g_replayPath = [path copy]; });
}

void IPALogServerStart(uint16_t port) {
    if (g_listenFd >= 0) return;    // already running

    g_queue = dispatch_queue_create("io.kiou.logserver", DISPATCH_QUEUE_SERIAL);

    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) {
        IPALog([NSString stringWithFormat:@"[LOGSVR] socket errno=%d", errno]);
        return;
    }

    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {0};
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);  // LAN-visible debug stream
    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        IPALog([NSString stringWithFormat:@"[LOGSVR] bind errno=%d port=%u",
                  errno, (unsigned)port]);
        close(s);
        return;
    }
    if (listen(s, IPA_LOG_SERVER_MAX_CLIENTS) < 0) {
        IPALog([NSString stringWithFormat:@"[LOGSVR] listen errno=%d", errno]);
        close(s);
        return;
    }
    ls_set_nonblock(s);
    g_listenFd = s;

    g_listenSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                                         (uintptr_t)s, 0, g_queue);
    dispatch_source_set_event_handler(g_listenSrc, ^{ ls_handle_accept(); });
    dispatch_resume(g_listenSrc);

    IPALog([NSString stringWithFormat:
              @"[LOGSVR] listening on 0.0.0.0:%u (debug build)", (unsigned)port]);
}

void IPALogServerPush(NSString *line) {
    if (!line || !g_queue) return;

    uint32_t pending = atomic_load(&g_pending);
    if (pending >= LOG_SERVER_QUEUE_DEPTH_MAX) {
        uint32_t dropped = atomic_fetch_add(&g_dropped, 1) + 1;
        if ((dropped % 64) == 0) {
            // Can't call IPALog here (would recurse); use NSLog directly.
            NSLog(@"[LOGSVR] drop backlog=%u dropped=%u", pending, dropped);
        }
        return;
    }

    atomic_fetch_add(&g_pending, 1);
    NSString *withNewline = [line hasSuffix:@"\n"]
        ? [line copy]
        : [line stringByAppendingString:@"\n"];

    dispatch_async(g_queue, ^{
        atomic_fetch_sub(&g_pending, 1);
        if (g_clientCount == 0) return;

        NSData *data = [withNewline dataUsingEncoding:NSUTF8StringEncoding];
        const uint8_t *bytes = (const uint8_t *)data.bytes;
        size_t len = data.length;

        // Drain inbound bytes first to catch dead peers before we try to send.
        for (int i = g_clientCount - 1; i >= 0; i--) {
            if (!ls_drain_client(g_clients[i])) {
                ls_evict_at(i);
            }
        }

        // Broadcast to surviving clients; evict on send failure.
        for (int i = g_clientCount - 1; i >= 0; i--) {
            if (!ls_send_all(g_clients[i], bytes, len)) {
                ls_evict_at(i);
            }
        }
    });
}

#endif  // !FINAL_RELEASE
