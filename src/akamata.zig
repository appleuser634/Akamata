// Akamata — Zig 製ミニマル Web フレームワーク。
//
// 公開 API はこのファイル経由でアクセスする。Hono 風の `App(State)` ベース
// + 既存 `Router(App)` 互換 API の両方を提供する。

const std = @import("std");
const builtin = @import("builtin");

const build_options = @import("build_options");

pub const Backend = enum { native, workers };
pub const backend: Backend = switch (build_options.backend) {
    .native => .native,
    .workers => .workers,
};

// ===== Hono-style new API =====
const app_mod = @import("app.zig");
pub const App = app_mod.App;
pub const Handler = app_mod.Handler;
pub const ErrorHandler = app_mod.ErrorHandler;
pub const Middleware = app_mod.Middleware;
pub const Next = app_mod.Next;
pub const ServeOptions = app_mod.ServeOptions;
pub const Runtime = app_mod.Runtime;
pub const RouteKind = app_mod.RouteKind;

const ctx_mod = @import("context.zig");
pub const Context = ctx_mod.Context;
pub const Params = ctx_mod.Params;

// Built-in middlewares (new API: take comptime State)
pub const mw = struct {
    pub const logger = @import("mw/logger.zig").logger;
    /// Alias kept for the legacy chat/mobus examples — same as `logger`.
    pub const requestLog = @import("mw/logger.zig").logger;
    pub const recover = @import("mw/recover.zig").recover;
    pub const cors = @import("mw/cors.zig").cors;
    pub const CorsOptions = @import("mw/cors.zig").Options;
    pub const secureHeaders = @import("mw/secure_headers.zig").secureHeaders;
    pub const SecureHeadersOptions = @import("mw/secure_headers.zig").Options;
    pub const compress = @import("mw/compress.zig").compress;
    pub const CompressOptions = @import("mw/compress.zig").Options;
    pub const etag = @import("mw/etag.zig").etag;
    pub const EtagOptions = @import("mw/etag.zig").Options;
    pub const bearerAuth = @import("mw/bearer.zig").bearerAuth;
    pub const BearerOptions = @import("mw/bearer.zig").Options;
    pub const jwt = @import("mw/jwt.zig").jwtAuth;
    pub const JwtOptions = @import("mw/jwt.zig").Options;
    pub const JwtClaims = @import("mw/jwt.zig").Claims;
    pub const currentJwtClaims = @import("mw/jwt.zig").currentClaims;
    pub const serveStatic = @import("mw/static.zig").serveStatic;
    pub const StaticOptions = @import("mw/static.zig").Options;
    pub const metrics = @import("mw/metrics.zig").metrics;
    pub const MetricsCounters = @import("mw/metrics.zig").Counters;
    pub const MetricsMethod = @import("mw/metrics.zig").Method;
    pub const metricsHandler = @import("mw/metrics.zig").metricsHandler;

    // v0.2 additions
    pub const session = @import("mw/session.zig").session;
    pub const SessionOptions = @import("mw/session.zig").Options;
    pub const Session = @import("mw/session.zig").Session;
    pub const SessionStore = @import("mw/session.zig").Store;
    pub const MemorySessionStore = @import("mw/session.zig").MemoryStore;
    pub const currentSession = @import("mw/session.zig").currentSession;

    pub const csrf = @import("mw/csrf.zig").csrf;
    pub const CsrfOptions = @import("mw/csrf.zig").Options;

    pub const rateLimit = @import("mw/ratelimit.zig").rateLimit;
    pub const RateLimitOptions = @import("mw/ratelimit.zig").Options;

    pub const requestId = @import("mw/requestid.zig").requestId;
    pub const currentRequestId = @import("mw/requestid.zig").currentRequestId;

    pub const accessLog = @import("mw/accesslog.zig").accessLog;
    pub const AccessLogFormat = @import("mw/accesslog.zig").Format;
};

// ===== Legacy (Router(App) + Ctx(App)) compatibility =====
//
// Existing examples still reference these names. They will eventually be
// removed; for now they continue to work alongside the new App API.

pub const http = struct {
    pub const Status = @import("http/status.zig").Code;
    pub const Method = @import("http/status.zig").Method;
    pub const Request = @import("http/request.zig").Request;
    pub const RequestHeader = @import("http/request.zig").Header;
    pub const Response = @import("http/response.zig").Response;
    pub const Header = @import("http/response.zig").Header;
    pub const parser = @import("http/parser.zig");
    pub const mime = @import("http/mime.zig");
    pub const multipart = @import("http/multipart.zig");
    pub const form = @import("http/form.zig");
    pub const cookie = @import("http/cookie.zig");
    pub const Server = if (backend == .native) @import("http/server.zig").Server else struct {};
};
pub const Request = http.Request;
pub const Response = http.Response;
pub const Status = http.Status;
pub const Method = http.Method;
pub const Server = http.Server;

pub const Router = @import("router.zig").Router;
pub const Route = @import("router.zig").Route;
// Re-export legacy RouteKind so existing tests/examples keep compiling. The
// new app-based RouteKind lives at `am.RouteKind` directly above.
const legacy_router = @import("router.zig");
pub const legacy = struct {
    pub const Ctx = @import("legacy_ctx.zig").Ctx;
    pub const middleware = @import("middleware.zig");
    pub const RouteKind = legacy_router.RouteKind;
};
pub const Ctx = legacy.Ctx;
pub const middleware = legacy.middleware;

// Server-Sent Events on top of chunked streaming. Native-only — Workers
// streaming requires the JS ReadableStream bridge (separate WIP).
pub const sse = if (backend == .native) @import("sse.zig") else struct {};

// OpenAPI 3.1 spec generation. Works on both backends — purely operates
// on the runtime route table.
pub const openapi = @import("openapi.zig");

// Type-safe client generator. Emits TypeScript or Zig client code from
// the same route metadata that openapi.generate uses.
pub const client_gen = @import("client_gen.zig");

// In-process test client + factories.
pub const testing = @import("testing.zig");

// Persistent SQLite-backed job queue + cron. Native-only. On Workers use
// Cron Triggers + Durable Object Alarms instead.
pub const jobs = if (backend == .native) @import("jobs.zig") else struct {};

// Content negotiation: pick the best media type from the request's Accept
// header against a server-provided allow-list.
pub const negotiate = @import("negotiate.zig");

// ===== Pure-byte modules (work on both backends) =====
pub const ws = struct {
    pub const frame = @import("ws/frame.zig");
    pub const handshake = @import("ws/handshake.zig");
    pub const Conn = if (backend == .native) @import("ws/conn.zig").Conn else struct {};
    pub const UpgradeOptions = if (backend == .native) @import("ws/conn.zig").UpgradeOptions else struct {};
    pub const Message = if (backend == .native) @import("ws/conn.zig").Message else struct {};
    pub const upgrade = if (backend == .native) @import("ws/conn.zig").upgrade else struct {};
    pub const Hub = @import("ws/hub.zig").Hub;
};

// ===== Persistence + integrations =====
pub const db = struct {
    const db_mod = @import("db/db.zig");
    const turso_mod = @import("db/turso.zig");
    pub const Db = db_mod.Db;
    pub const Stmt = db_mod.Stmt;
    pub const Value = db_mod.Value;
    pub const VTable = db_mod.VTable;
    pub const StmtVTable = db_mod.StmtVTable;
    pub const StepResult = db_mod.StepResult;

    // Backend-specific openers. Use `open(url)` (below) for portable code.
    pub const openSqlite = if (backend == .native) @import("db/sqlite.zig").open else struct {}.@"openSqlite-workers-only";
    pub const openD1 = if (backend == .workers) @import("db/d1.zig").open else struct {}.@"openD1-native-only";
    pub const openTurso = turso_mod.open;
    pub const TursoOptions = turso_mod.Options;
    pub const TursoError = turso_mod.TursoError;

    /// Union of every error any backend may return from its `open` (so the
    /// portable factory can propagate transparently).
    pub const OpenError = error{
        UnknownScheme,
        UnsupportedOnBackend,
        InvalidUrl,
        OutOfMemory,
        // sqlite backend
        OpenFailed,
        PrepareFailed,
        BindFailed,
        StepFailed,
        ExecFailed,
        InvalidUtf8,
    } || turso_mod.TursoError;

    /// Portable opener. Inspects the URL scheme and picks the right backend.
    /// Works identically on native and Workers; if the scheme can't run on the
    /// current backend (`file:` on Workers, `d1:` on native) it returns
    /// `error.UnsupportedOnBackend` so callers fail fast.
    ///
    /// Supported schemes:
    ///   * `file:PATH`             — local SQLite file (native only)
    ///   * `libsql://HOST?authToken=…` / `https://HOST` — Turso Hrana over HTTP
    ///   * `d1:BINDING`            — Cloudflare D1 (Workers only)
    pub fn open(gpa: std.mem.Allocator, url: []const u8) OpenError!Db {
        if (std.mem.startsWith(u8, url, "file:")) {
            if (backend != .native) return error.UnsupportedOnBackend;
            return openSqlite(gpa, url[5..]);
        }
        if (std.mem.startsWith(u8, url, "libsql://") or
            std.mem.startsWith(u8, url, "https://") or
            std.mem.startsWith(u8, url, "http://"))
        {
            return openTurso(gpa, .{ .url = url });
        }
        if (std.mem.startsWith(u8, url, "d1:")) {
            if (backend != .workers) return error.UnsupportedOnBackend;
            // D1 binding name is currently fixed; the URL is ignored here.
            return openD1(gpa);
        }
        return error.UnknownScheme;
    }
};

pub const json = @import("json.zig");
pub const log = @import("log.zig");
pub const errors = @import("errors.zig");
pub const env = @import("env.zig");
pub const sync = @import("sync.zig");
pub const Mutex = sync.Mutex;

pub const auth = struct {
    pub const jwt = @import("auth/jwt.zig");
    pub const bcrypt = @import("auth/bcrypt.zig");
};

pub const crypto = struct {
    pub const rs256 = @import("crypto/rs256.zig");
};

pub const http_client = @import("http_client.zig");
pub const push = @import("push.zig");
pub const mq = @import("mq.zig");
pub const model = @import("model/model.zig");

pub const runtime = struct {
    pub const native = if (backend == .native) @import("runtime/native.zig") else struct {};
    pub const workers = if (backend == .workers) @import("runtime/workers.zig") else struct {};
};

/// Native entrypoint for legacy Server(App) callers. New code uses
/// `App(State).serve()` directly.
pub fn runNative(server: anytype) !void {
    if (backend != .native) @compileError("runNative is only available on native backend");
    return runtime.native.run(@TypeOf(server.*), server);
}

/// Build helper to embed in user-project build.zig files.
pub const akamata_build = @import("build_helpers/akamata_build.zig");
