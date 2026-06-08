// Cloudflare Workers entry for mobus, with full D1 support via JSPI.
//
// JSPI (JavaScript Promise Integration) lets us wrap async functions with
// `new WebAssembly.Suspending(fn)` so that, from the wasm/Zig side, they
// look like ordinary synchronous calls. The wasm export is wrapped with
// `WebAssembly.promising(...)` so the JS host can `await` it.
//
// Net effect: Zig handlers call `db.prepare(...).step()` exactly the same
// way they do against SQLite/Turso. The V8 / Workers runtime parks the
// wasm stack while D1 awaits and resumes it transparently.

import wasm from "../../../zig-out/bin/mobus_worker.wasm";

let instance, memory, exports_ref, handleFetchAsync;
let jspi_supported = false;

// === D1 statement registry (Workers-side state) ===
//
// Each call to d1_prepare returns a handle (i32) that Zig holds while it
// binds parameters and iterates rows. The actual D1 PreparedStatement
// (and the row iterator from .raw({columnNames:true})) live here.
const d1stmts = new Map();
let nextStmtId = 1;
let activeEnv = null;

function stmtRegistryAlloc(entry) {
  const id = nextStmtId++;
  d1stmts.set(id, entry);
  return id;
}

// Memory helpers — re-fetched on every call because JSPI suspends may have
// grown `memory.buffer` and detached previous Uint8Array views.
function readBytes(ptr, len) { return new Uint8Array(memory.buffer, ptr, len); }
function readString(ptr, len) { return new TextDecoder().decode(readBytes(ptr, len)); }
function writeBytes(ptr, bytes) { new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes); }

// JSPI feature detection. Older runtimes (Wrangler pre-3.99, very old
// Miniflare) might lack `WebAssembly.Suspending`; in that case we fall
// back to the legacy `-2` BridgeNotImplemented sentinel so Zig handlers
// see a clean error rather than hanging.
function detectJspi() {
  jspi_supported =
    typeof WebAssembly.Suspending === "function" &&
    typeof WebAssembly.promising === "function";
  return jspi_supported;
}

// Wrap an async function so wasm sees a synchronous import. Without JSPI we
// return -2 (BridgeNotImplemented) so Zig surfaces a clean 503.
function suspending(fn) {
  if (jspi_supported) return new WebAssembly.Suspending(fn);
  return () => -2;
}

async function instantiate(env) {
  if (instance) return;
  activeEnv = env;
  detectJspi();

  // --- akamata_env: synchronous accessors (no JSPI needed) ---
  const envBridge = {
    akamata_env_get(name_ptr, name_len, out_ptr, out_cap) {
      const k = readString(name_ptr, name_len);
      const v = env?.[k];
      if (v == null) return -1;
      const bytes = new TextEncoder().encode(String(v));
      if (bytes.length > out_cap) return bytes.length;
      writeBytes(out_ptr, bytes);
      return bytes.length;
    },
    akamata_random_bytes(p, l) {
      const b = new Uint8Array(l);
      crypto.getRandomValues(b);
      writeBytes(p, b);
    },
    akamata_unix_seconds() {
      return BigInt(Math.floor(Date.now() / 1000));
    },
  };

  // --- akamata_d1: every Promise-returning call wrapped with Suspending ---
  const d1 = env.DB;
  const d1Bridge = {
    // PREPARE — synchronous on D1 (.prepare returns a PreparedStatement),
    // but we keep it Suspending-compatible in case the runtime changes.
    // Synchronous: D1's .prepare() does no I/O, so wrapping it in Suspending
    // only buys a wasted wasm stack suspend/resume. The one async step per
    // statement happens in d1_run.
    d1_prepare(sql_ptr, sql_len) {
      if (!d1) return -2;
      try {
        const sql = readString(sql_ptr, sql_len);
        const stmt = d1.prepare(sql);
        return stmtRegistryAlloc({
          base: stmt,
          bindArgs: [],
          rows: null,
          cursor: 0,
          currentRow: null,
          columnNames: null,
        });
      } catch (e) {
        console.error("d1_prepare failed:", e?.message ?? e);
        return -3;
      }
    },

    // BIND family — D1's .bind() returns a *new* PreparedStatement clone
    // with the values baked in. We accumulate the args in JS-side state and
    // call .bind(...args) lazily right before step() so the order matches.
    d1_bind_int64(h, idx, val) {
      const e = d1stmts.get(h); if (!e) return -1;
      e.bindArgs[idx - 1] = Number(val);
      return 0;
    },
    d1_bind_double(h, idx, val) {
      const e = d1stmts.get(h); if (!e) return -1;
      e.bindArgs[idx - 1] = val;
      return 0;
    },
    d1_bind_text(h, idx, ptr, len) {
      const e = d1stmts.get(h); if (!e) return -1;
      e.bindArgs[idx - 1] = readString(ptr, len);
      return 0;
    },
    d1_bind_blob(h, idx, ptr, len) {
      const e = d1stmts.get(h); if (!e) return -1;
      e.bindArgs[idx - 1] = readBytes(ptr, len).slice();
      return 0;
    },
    d1_bind_null(h, idx) {
      const e = d1stmts.get(h); if (!e) return -1;
      e.bindArgs[idx - 1] = null;
      return 0;
    },

    // RUN — the only async D1 op per statement. Binds and materialises the
    // full result set via `.raw({columnNames:true})` (arrays + headers in one
    // go). Zig calls this lazily on the first step(). Returns the row count.
    // Pulling the await out of the per-row step removes one JSPI suspend/resume
    // per row.
    d1_run: suspending(async (h) => {
      const e = d1stmts.get(h);
      if (!e) return -1;
      try {
        const bound = e.bindArgs.length > 0 ? e.base.bind(...e.bindArgs) : e.base;
        const out = await bound.raw({ columnNames: true });
        if (Array.isArray(out) && out.length > 0) {
          e.columnNames = out[0];
          e.rows = out.slice(1);
        } else {
          e.columnNames = [];
          e.rows = [];
        }
        e.cursor = 0;
        return e.rows.length;
      } catch (err) {
        console.error("d1_run failed:", err?.message ?? err);
        return -4;
      }
    }),

    // STEP — synchronous cursor advance over the rows from d1_run. No JSPI
    // suspend; this is the hot per-row call.
    d1_step(h) {
      const e = d1stmts.get(h);
      if (!e || e.rows == null) return -1;
      if (e.cursor >= e.rows.length) {
        e.currentRow = null;
        return 0;
      }
      e.currentRow = e.rows[e.cursor++];
      return 1;
    },

    // COLUMN family — pure JS-side reads from the most recent row.
    d1_column_int64(h, idx) {
      const e = d1stmts.get(h);
      if (!e || !e.currentRow) return BigInt(0);
      const v = e.currentRow[idx];
      if (v == null) return BigInt(0);
      if (typeof v === "bigint") return v;
      if (typeof v === "number") return BigInt(Math.trunc(v));
      if (typeof v === "string") { try { return BigInt(v); } catch { return BigInt(0); } }
      return BigInt(0);
    },
    d1_column_double(h, idx) {
      const e = d1stmts.get(h);
      if (!e || !e.currentRow) return 0;
      const v = e.currentRow[idx];
      return v == null ? 0 : Number(v);
    },
    d1_column_text_len(h, idx) {
      const e = d1stmts.get(h);
      if (!e || !e.currentRow) return 0;
      const v = e.currentRow[idx];
      if (v == null) return 0;
      if (v instanceof Uint8Array || v instanceof ArrayBuffer) return v.byteLength;
      return new TextEncoder().encode(String(v)).length;
    },
    d1_column_text_copy(h, idx, out_ptr, out_len) {
      const e = d1stmts.get(h);
      if (!e || !e.currentRow) return 0;
      const v = e.currentRow[idx];
      if (v == null) return 0;
      let bytes;
      if (v instanceof Uint8Array) bytes = v;
      else if (v instanceof ArrayBuffer) bytes = new Uint8Array(v);
      else bytes = new TextEncoder().encode(String(v));
      const n = Math.min(bytes.length, out_len);
      writeBytes(out_ptr, bytes.subarray(0, n));
      return n;
    },
    d1_column_count(h) {
      const e = d1stmts.get(h);
      if (!e) return 0;
      if (e.columnNames) return e.columnNames.length;
      if (e.currentRow) return e.currentRow.length;
      return 0;
    },
    d1_reset(h) {
      const e = d1stmts.get(h);
      if (!e) return;
      e.rows = null;
      e.cursor = 0;
      e.currentRow = null;
    },
    d1_finalize(h) {
      d1stmts.delete(h);
    },

    // EXEC — one-shot SQL with no row capture. Used by migrations.
    // We route through .prepare().run() rather than .exec(), because D1's
    // .exec() requires `;`-terminated statements and the model migrator
    // emits single unterminated DDL.
    d1_exec: suspending(async (sql_ptr, sql_len) => {
      if (!d1) return -2;
      try {
        const sql = readString(sql_ptr, sql_len);
        await d1.prepare(sql).run();
        return 0;
      } catch (e) {
        console.error("d1_exec failed:", e?.message ?? e);
        return -3;
      }
    }),
  };

  // --- akamata_http: outbound HTTP via JS fetch() (used by Turso/libsql, FCM, …) ---
  //
  // Contract with src/http_client.zig:
  //   req bytes = "METHOD\nURL\nheader: value\n...\n\nBODY"
  //   write the raw HTTP/1.1 response ("HTTP/1.1 STATUS …\r\nname: value\r\n\r\nBODY")
  //   into a wasm-side buffer allocated with exports.alloc(len), then return
  //   the pointer/length through the two out_ptr/out_len memory slots.
  const httpBridge = {
    akamata_fetch: suspending(async (req_ptr, req_len, out_ptr_addr, out_len_addr) => {
      try {
        const reqStr = readString(req_ptr, req_len);
        const nl = reqStr.indexOf("\n");
        if (nl < 0) return -1;
        const method = reqStr.slice(0, nl);
        const rest1 = reqStr.slice(nl + 1);
        const nl2 = rest1.indexOf("\n");
        if (nl2 < 0) return -1;
        const url = rest1.slice(0, nl2);
        const rest2 = rest1.slice(nl2 + 1);
        const headerEnd = rest2.indexOf("\n\n");
        if (headerEnd < 0) return -1;
        const headerBlock = rest2.slice(0, headerEnd);
        const body = rest2.slice(headerEnd + 2);

        const headers = new Headers();
        if (headerBlock.length > 0) {
          for (const line of headerBlock.split("\n")) {
            const i = line.indexOf(":");
            if (i < 0) continue;
            headers.set(line.slice(0, i).trim(), line.slice(i + 1).trim());
          }
        }

        const init = { method, headers };
        if (method !== "GET" && method !== "HEAD" && body.length > 0) {
          init.body = body;
        }
        const resp = await fetch(url, init);
        const respBody = new Uint8Array(await resp.arrayBuffer());

        // Build a raw HTTP/1.1 response that http_client.parseResponse expects.
        let head = `HTTP/1.1 ${resp.status} ${resp.statusText || ""}\r\n`;
        for (const [k, v] of resp.headers) {
          // Drop transfer-encoding: the body is already fully buffered.
          if (k.toLowerCase() === "transfer-encoding") continue;
          head += `${k}: ${v}\r\n`;
        }
        head += `content-length: ${respBody.length}\r\n\r\n`;
        const headBytes = new TextEncoder().encode(head);
        const total = headBytes.length + respBody.length;

        const buf_ptr = exports_ref.alloc(total);
        writeBytes(buf_ptr, headBytes);
        writeBytes(buf_ptr + headBytes.length, respBody);

        // Write back the pointer/length into the *usize/*usize slots.
        const dv = new DataView(memory.buffer);
        const ptrSize = 4; // wasm32
        dv.setUint32(out_ptr_addr, buf_ptr, true);
        dv.setUint32(out_len_addr, total, true);
        return 0;
      } catch (err) {
        console.error("akamata_fetch failed:", err?.message ?? err);
        return -2;
      }
    }),
  };

  const imports = {
    akamata_env: envBridge,
    akamata_d1: d1Bridge,
    akamata_http: httpBridge,
  };

  instance = await WebAssembly.instantiate(wasm, imports);
  exports_ref = instance.exports;
  memory = exports_ref.memory;

  // Wrap the wasm dispatch entry so `await handleFetchAsync(...)` resolves
  // even when D1 imports suspended the wasm stack midway through.
  if (jspi_supported && typeof exports_ref.handle_fetch === "function") {
    handleFetchAsync = WebAssembly.promising(exports_ref.handle_fetch);
  } else {
    handleFetchAsync = (ptr, len) => exports_ref.handle_fetch(ptr, len);
  }

  if (typeof exports_ref.akamata_init === "function") exports_ref.akamata_init();
}

export default {
  async fetch(request, env, ctx) {
    activeEnv = env;
    await instantiate(env);

    const url = new URL(request.url);
    // Route WebSocket upgrades directly to the UserHub DO.
    if (url.pathname === "/api/ws" && request.headers.get("Upgrade") === "websocket") {
      const token = url.searchParams.get("token") ?? request.headers.get("authorization")?.slice(7);
      if (!token) return new Response("missing token", { status: 401 });
      const id = env.USER_HUB.idFromName(token);
      const obj = env.USER_HUB.get(id);
      return obj.fetch(request);
    }

    const bodyBuf = new Uint8Array(await request.arrayBuffer());
    const headers = [];
    for (const [k, v] of request.headers) headers.push(`${k}: ${v}`);
    const head = `${request.method} ${url.pathname}${url.search} HTTP/1.1\r\nhost: ${url.host}\r\n${headers.join("\r\n")}\r\ncontent-length: ${bodyBuf.length}\r\n\r\n`;
    const headBytes = new TextEncoder().encode(head);
    const total = headBytes.length + bodyBuf.length;

    const ptr = exports_ref.alloc(total);
    writeBytes(ptr, headBytes);
    writeBytes(ptr + headBytes.length, bodyBuf);

    // JSPI: handle_fetch may suspend while D1 calls await — `await` parks
    // until the wasm stack resumes with the final response pointer.
    const respPtr = await handleFetchAsync(ptr, total);
    const respLen = exports_ref.last_response_length();
    if (respPtr === 0) {
      exports_ref.dealloc(ptr, total);
      return new Response("internal error", { status: 500 });
    }
    const respBytes = new Uint8Array(memory.buffer, respPtr, respLen).slice();
    exports_ref.dealloc(ptr, total);
    exports_ref.dealloc(respPtr, respLen);

    return parseHttpResponse(respBytes);
  },
};

function parseHttpResponse(bytes) {
  const sep = findHeaderEnd(bytes);
  if (sep < 0) return new Response("invalid wasm response", { status: 502 });
  const headStr = new TextDecoder().decode(bytes.subarray(0, sep));
  const body = bytes.subarray(sep + 4);
  const lines = headStr.split("\r\n");
  const status = parseInt(lines[0].split(" ")[1], 10);
  const headers = new Headers();
  for (let i = 1; i < lines.length; i++) {
    const idx = lines[i].indexOf(":");
    if (idx < 0) continue;
    headers.set(lines[i].slice(0, idx).trim(), lines[i].slice(idx + 1).trim());
  }
  return new Response(body, { status, headers });
}

function findHeaderEnd(bytes) {
  for (let i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] === 13 && bytes[i + 1] === 10 && bytes[i + 2] === 13 && bytes[i + 3] === 10) return i;
  }
  return -1;
}

export { UserHub } from "./user_hub.mjs";
