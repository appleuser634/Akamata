// Cloudflare Workers entry for the chat example, with full D1 support via JSPI.
//
// JSPI (JavaScript Promise Integration) lets async imports look synchronous
// to wasm/Zig: we wrap each D1 call with `new WebAssembly.Suspending(fn)` and
// wrap the wasm entry point with `WebAssembly.promising(handle_fetch)`. The
// V8 runtime parks the wasm stack across awaits and resumes it transparently.
//
// Net effect: Zig handlers call `db.prepare(...).step()` against D1 with the
// exact same code path used for SQLite/Turso.

import wasm from "../../zig-out/bin/chat_worker.wasm";

let instance, memory, exports_ref, handleFetchAsync;
let jspi_supported = false;

// === D1 statement registry ===
const d1stmts = new Map();
let nextStmtId = 1;
let activeEnv = null;

function stmtRegistryAlloc(entry) {
  const id = nextStmtId++;
  d1stmts.set(id, entry);
  return id;
}

function readBytes(ptr, len) { return new Uint8Array(memory.buffer, ptr, len); }
function readString(ptr, len) { return new TextDecoder().decode(readBytes(ptr, len)); }
function writeBytes(ptr, bytes) { new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes); }

function detectJspi() {
  jspi_supported =
    typeof WebAssembly.Suspending === "function" &&
    typeof WebAssembly.promising === "function";
  return jspi_supported;
}

// Wraps an async function so wasm sees a synchronous import. Falls back to
// the -2 BridgeNotImplemented sentinel when JSPI isn't available.
function suspending(fn) {
  if (jspi_supported) return new WebAssembly.Suspending(fn);
  return () => -2;
}

async function instantiate(env) {
  if (instance) return;
  activeEnv = env;
  detectJspi();

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

  const d1 = env.DB;
  const d1Bridge = {
    // Synchronous: D1's .prepare() does no I/O, so wrapping it in Suspending
    // only buys a wasted wasm stack suspend/resume. The single async step per
    // statement happens in d1_run below.
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

    // The ONLY async D1 operation per statement: bind + run, materialising the
    // full result set into e.rows. The Zig side calls this lazily on the first
    // step() (binds land between prepare and step). Returns the row count, or a
    // negative sentinel (-2 bridge missing, -4 query error). Collapsing the
    // per-row await out of d1_step removes one JSPI suspend/resume per row.
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

    // Synchronous cursor advance over the rows materialised by d1_run. No JSPI
    // suspend — this is the hot per-row call. Returns 1 (row), 0 (done), or -1.
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
      // Drop the materialised rows so the next step() re-runs d1_run.
      e.rows = null;
      e.cursor = 0;
      e.currentRow = null;
    },
    d1_finalize(h) {
      d1stmts.delete(h);
    },

    d1_exec: suspending(async (sql_ptr, sql_len) => {
      if (!d1) return -2;
      try {
        // .prepare().run() instead of .exec() — see deploy/guestbook/worker/index.mjs
        // for the rationale (D1 .exec requires ; + \n separation that our DDL
        // emitter doesn't produce).
        const sql = readString(sql_ptr, sql_len);
        await d1.prepare(sql).run();
        return 0;
      } catch (e) {
        console.error("d1_exec failed:", e?.message ?? e);
        return -3;
      }
    }),
  };

  // --- akamata_http: outbound HTTP via JS fetch() (used by Turso/libsql, …) ---
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
        if (method !== "GET" && method !== "HEAD" && body.length > 0) init.body = body;
        const resp = await fetch(url, init);
        const respBody = new Uint8Array(await resp.arrayBuffer());

        let head = `HTTP/1.1 ${resp.status} ${resp.statusText || ""}\r\n`;
        for (const [k, v] of resp.headers) {
          if (k.toLowerCase() === "transfer-encoding") continue;
          head += `${k}: ${v}\r\n`;
        }
        head += `content-length: ${respBody.length}\r\n\r\n`;
        const headBytes = new TextEncoder().encode(head);
        const total = headBytes.length + respBody.length;

        const buf_ptr = exports_ref.alloc(total);
        writeBytes(buf_ptr, headBytes);
        writeBytes(buf_ptr + headBytes.length, respBody);

        const dv = new DataView(memory.buffer);
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
    // Route WebSocket upgrades directly to the ChatRoom DO.
    const wsMatch = url.pathname.match(/^\/rooms\/(\d+)\/ws$/);
    if (wsMatch && request.headers.get("Upgrade") === "websocket") {
      const id = env.CHAT_ROOM.idFromName(wsMatch[1]);
      const obj = env.CHAT_ROOM.get(id);
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

export { ChatRoom } from "./chat_room.mjs";
