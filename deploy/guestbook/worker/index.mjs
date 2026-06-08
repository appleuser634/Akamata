// Cloudflare Workers entry for the guestbook example.
//
// Full D1 and Turso support via JSPI:
//   - D1 calls are wrapped in `new WebAssembly.Suspending(fn)`.
//   - Outbound HTTP (Turso/libsql, any external API the Zig side calls
//     through am.http_client) is also wrapped via the same JSPI primitive.
//   - The wasm entry `handle_fetch` is wrapped with `WebAssembly.promising`.
//
// Net effect: the same Zig code that runs against SQLite on a VPS runs
// against D1 or Turso here, with no source changes.

import wasm from "../../../zig-out/bin/guestbook_worker.wasm";

let instance, memory, exports_ref, handleFetchAsync;
let jspi_supported = false;

const d1stmts = new Map();
let nextStmtId = 1;

function readBytes(p, l) { return new Uint8Array(memory.buffer, p, l); }
function readString(p, l) { return new TextDecoder().decode(readBytes(p, l)); }
function writeBytes(p, b) { new Uint8Array(memory.buffer, p, b.length).set(b); }

function detectJspi() {
  jspi_supported =
    typeof WebAssembly.Suspending === "function" &&
    typeof WebAssembly.promising === "function";
  return jspi_supported;
}
function suspending(fn) {
  return jspi_supported ? new WebAssembly.Suspending(fn) : () => -2;
}

async function instantiate(env) {
  if (instance) return;
  detectJspi();

  const envBridge = {
    akamata_env_get(np, nl, op, oc) {
      const k = readString(np, nl);
      const v = env?.[k];
      if (v == null) return -1;
      const bytes = new TextEncoder().encode(String(v));
      if (bytes.length > oc) return bytes.length;
      writeBytes(op, bytes);
      return bytes.length;
    },
    akamata_random_bytes(p, l) {
      const b = new Uint8Array(l);
      crypto.getRandomValues(b);
      writeBytes(p, b);
    },
    akamata_unix_seconds() { return BigInt(Math.floor(Date.now() / 1000)); },
  };

  const d1 = env.DB;
  const d1Bridge = {
    // Synchronous: D1's .prepare() does no I/O. The one async step per
    // statement happens in d1_run.
    d1_prepare(sp, sl) {
      if (!d1) return -2;
      try {
        const stmt = d1.prepare(readString(sp, sl));
        const id = nextStmtId++;
        d1stmts.set(id, { base: stmt, bindArgs: [], rows: null, cursor: 0, currentRow: null, columnNames: null });
        return id;
      } catch (e) { console.error("d1_prepare:", e?.message ?? e); return -3; }
    },
    d1_bind_int64(h, i, v) { const e = d1stmts.get(h); if (!e) return -1; e.bindArgs[i-1] = Number(v); return 0; },
    d1_bind_double(h, i, v) { const e = d1stmts.get(h); if (!e) return -1; e.bindArgs[i-1] = v; return 0; },
    d1_bind_text(h, i, p, l) { const e = d1stmts.get(h); if (!e) return -1; e.bindArgs[i-1] = readString(p, l); return 0; },
    d1_bind_blob(h, i, p, l) { const e = d1stmts.get(h); if (!e) return -1; e.bindArgs[i-1] = readBytes(p, l).slice(); return 0; },
    d1_bind_null(h, i) { const e = d1stmts.get(h); if (!e) return -1; e.bindArgs[i-1] = null; return 0; },
    // The only async D1 op per statement: bind + run, materialising all rows.
    // Zig calls this lazily on the first step. Removing the per-row await from
    // d1_step drops one JSPI suspend per row.
    d1_run: suspending(async (h) => {
      const e = d1stmts.get(h); if (!e) return -1;
      try {
        const bound = e.bindArgs.length > 0 ? e.base.bind(...e.bindArgs) : e.base;
        const out = await bound.raw({ columnNames: true });
        if (Array.isArray(out) && out.length > 0) {
          e.columnNames = out[0];
          e.rows = out.slice(1);
        } else { e.columnNames = []; e.rows = []; }
        e.cursor = 0;
        return e.rows.length;
      } catch (err) { console.error("d1_run:", err?.message ?? err); return -4; }
    }),
    // Synchronous cursor advance over the rows from d1_run — no JSPI suspend.
    d1_step(h) {
      const e = d1stmts.get(h); if (!e || e.rows == null) return -1;
      if (e.cursor >= e.rows.length) { e.currentRow = null; return 0; }
      e.currentRow = e.rows[e.cursor++];
      return 1;
    },
    d1_column_int64(h, i) {
      const e = d1stmts.get(h); if (!e || !e.currentRow) return BigInt(0);
      const v = e.currentRow[i];
      if (v == null) return BigInt(0);
      if (typeof v === "bigint") return v;
      if (typeof v === "number") return BigInt(Math.trunc(v));
      if (typeof v === "string") { try { return BigInt(v); } catch { return BigInt(0); } }
      return BigInt(0);
    },
    d1_column_double(h, i) {
      const e = d1stmts.get(h); if (!e || !e.currentRow) return 0;
      const v = e.currentRow[i]; return v == null ? 0 : Number(v);
    },
    d1_column_text_len(h, i) {
      const e = d1stmts.get(h); if (!e || !e.currentRow) return 0;
      const v = e.currentRow[i];
      if (v == null) return 0;
      if (v instanceof Uint8Array || v instanceof ArrayBuffer) return v.byteLength;
      return new TextEncoder().encode(String(v)).length;
    },
    d1_column_text_copy(h, i, op, ol) {
      const e = d1stmts.get(h); if (!e || !e.currentRow) return 0;
      const v = e.currentRow[i]; if (v == null) return 0;
      let bytes;
      if (v instanceof Uint8Array) bytes = v;
      else if (v instanceof ArrayBuffer) bytes = new Uint8Array(v);
      else bytes = new TextEncoder().encode(String(v));
      const n = Math.min(bytes.length, ol);
      writeBytes(op, bytes.subarray(0, n));
      return n;
    },
    d1_column_count(h) {
      const e = d1stmts.get(h); if (!e) return 0;
      if (e.columnNames) return e.columnNames.length;
      if (e.currentRow) return e.currentRow.length;
      return 0;
    },
    d1_reset(h) { const e = d1stmts.get(h); if (!e) return; e.rows = null; e.cursor = 0; e.currentRow = null; },
    d1_finalize(h) { d1stmts.delete(h); },
    // Use .prepare().run() rather than .exec(). D1's .exec() requires every
    // statement to end with `;` and be `\n`-separated; our model migrator
    // emits single, unterminated DDL statements. .prepare().run() doesn't
    // care about trailing punctuation, which matches SQLite's behaviour.
    d1_exec: suspending(async (sp, sl) => {
      if (!d1) return -2;
      try { await d1.prepare(readString(sp, sl)).run(); return 0; }
      catch (e) { console.error("d1_exec:", e?.message ?? e); return -3; }
    }),
  };

  const httpBridge = {
    akamata_fetch: suspending(async (rp, rl, op_addr, ol_addr) => {
      try {
        const s = readString(rp, rl);
        const nl = s.indexOf("\n"); if (nl < 0) return -1;
        const method = s.slice(0, nl);
        const r1 = s.slice(nl + 1);
        const nl2 = r1.indexOf("\n"); if (nl2 < 0) return -1;
        const url = r1.slice(0, nl2);
        const r2 = r1.slice(nl2 + 1);
        const he = r2.indexOf("\n\n"); if (he < 0) return -1;
        const hb = r2.slice(0, he), body = r2.slice(he + 2);

        const headers = new Headers();
        if (hb.length > 0) for (const line of hb.split("\n")) {
          const ci = line.indexOf(":"); if (ci < 0) continue;
          headers.set(line.slice(0, ci).trim(), line.slice(ci + 1).trim());
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
        const buf = exports_ref.alloc(total);
        writeBytes(buf, headBytes);
        writeBytes(buf + headBytes.length, respBody);
        const dv = new DataView(memory.buffer);
        dv.setUint32(op_addr, buf, true);
        dv.setUint32(ol_addr, total, true);
        return 0;
      } catch (e) { console.error("akamata_fetch:", e?.message ?? e); return -2; }
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

  handleFetchAsync = (jspi_supported && typeof exports_ref.handle_fetch === "function")
    ? WebAssembly.promising(exports_ref.handle_fetch)
    : (p, l) => exports_ref.handle_fetch(p, l);

  if (typeof exports_ref.akamata_init === "function") exports_ref.akamata_init();
}

export default {
  async fetch(request, env, ctx) {
    await instantiate(env);

    const url = new URL(request.url);
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

    const sep = findHeaderEnd(respBytes);
    if (sep < 0) return new Response("invalid wasm response", { status: 502 });
    const headStr = new TextDecoder().decode(respBytes.subarray(0, sep));
    const respBody = respBytes.subarray(sep + 4);
    const lines = headStr.split("\r\n");
    const status = parseInt(lines[0].split(" ")[1], 10);
    const respHeaders = new Headers();
    for (let i = 1; i < lines.length; i++) {
      const ci = lines[i].indexOf(":");
      if (ci < 0) continue;
      respHeaders.set(lines[i].slice(0, ci).trim(), lines[i].slice(ci + 1).trim());
    }
    return new Response(respBody, { status, headers: respHeaders });
  },
};

function findHeaderEnd(bytes) {
  for (let i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] === 13 && bytes[i+1] === 10 && bytes[i+2] === 13 && bytes[i+3] === 10) return i;
  }
  return -1;
}
