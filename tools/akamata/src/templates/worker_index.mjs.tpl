// Cloudflare Workers entry. Loads the Zig-built wasm and bridges HTTP requests.
//
// D1 support uses JSPI (JavaScript Promise Integration): async imports are
// wrapped in `new WebAssembly.Suspending(fn)` and `handle_fetch` is wrapped
// in `WebAssembly.promising(...)` so Zig-side code can call D1 synchronously.

import wasm from "../../zig-out/bin/{{NAME}}_worker.wasm";

let instance, memory, exp, handleFetchAsync;
let jspi = false;

const d1stmts = new Map();
let nextStmtId = 1;

function readBytes(p, l) { return new Uint8Array(memory.buffer, p, l); }
function readStr(p, l) { return new TextDecoder().decode(readBytes(p, l)); }
function writeBytes(p, b) { new Uint8Array(memory.buffer, p, b.length).set(b); }

function detectJspi() {
  jspi = typeof WebAssembly.Suspending === "function" &&
         typeof WebAssembly.promising === "function";
  return jspi;
}
function suspending(fn) {
  return jspi ? new WebAssembly.Suspending(fn) : () => -2;
}

async function init(env) {
  if (instance) return;
  detectJspi();

  const envBridge = {
    akamata_env_get(np, nl, op, oc) {
      const k = readStr(np, nl);
      const v = env?.[k];
      if (v == null) return -1;
      const bytes = new TextEncoder().encode(String(v));
      if (bytes.length > oc) return bytes.length;
      writeBytes(op, bytes);
      return bytes.length;
    },
    akamata_random_bytes(p, l) {
      const b = new Uint8Array(l); crypto.getRandomValues(b);
      writeBytes(p, b);
    },
    akamata_unix_seconds() { return BigInt(Math.floor(Date.now() / 1000)); },
  };

  const d1 = env.DB;
  const d1Bridge = {
    d1_prepare: suspending(async (sp, sl) => {
      if (!d1) return -2;
      try {
        const stmt = d1.prepare(readStr(sp, sl));
        const id = nextStmtId++;
        d1stmts.set(id, { base: stmt, bindArgs: [], iter: null, currentRow: null, columnNames: null });
        return id;
      } catch (e) { console.error("d1_prepare:", e?.message ?? e); return -3; }
    }),
    d1_bind_int64(h, i, v) { const e = d1stmts.get(h); if (!e) return -1; e.bindArgs[i-1] = Number(v); return 0; },
    d1_bind_double(h, i, v) { const e = d1stmts.get(h); if (!e) return -1; e.bindArgs[i-1] = v; return 0; },
    d1_bind_text(h, i, p, l) { const e = d1stmts.get(h); if (!e) return -1; e.bindArgs[i-1] = readStr(p, l); return 0; },
    d1_bind_blob(h, i, p, l) { const e = d1stmts.get(h); if (!e) return -1; e.bindArgs[i-1] = readBytes(p, l).slice(); return 0; },
    d1_bind_null(h, i) { const e = d1stmts.get(h); if (!e) return -1; e.bindArgs[i-1] = null; return 0; },
    d1_step: suspending(async (h) => {
      const e = d1stmts.get(h); if (!e) return -1;
      try {
        if (!e.iter) {
          const bound = e.bindArgs.length > 0 ? e.base.bind(...e.bindArgs) : e.base;
          const out = await bound.raw({ columnNames: true });
          if (Array.isArray(out) && out.length > 0) {
            e.columnNames = out[0];
            e.iter = out.slice(1)[Symbol.iterator]();
          } else { e.columnNames = []; e.iter = [][Symbol.iterator](); }
        }
        const n = e.iter.next();
        if (n.done) return 0;
        e.currentRow = n.value;
        return 1;
      } catch (err) { console.error("d1_step:", err?.message ?? err); return -4; }
    }),
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
    d1_reset(h) { const e = d1stmts.get(h); if (!e) return; e.iter = null; e.currentRow = null; },
    d1_finalize(h) { d1stmts.delete(h); },
    // .prepare().run() instead of .exec() — model-generated DDL is one
    // unterminated statement at a time, and D1's .exec() requires ;-terminated
    // statements separated by newlines.
    d1_exec: suspending(async (sp, sl) => {
      if (!d1) return -2;
      try { await d1.prepare(readStr(sp, sl)).run(); return 0; }
      catch (e) { console.error("d1_exec:", e?.message ?? e); return -3; }
    }),
  };

  // Outbound HTTP via JS fetch (Turso, FCM, any external API the Zig side
  // calls through am.http_client.send). Wrapped in Suspending so it looks
  // synchronous to wasm.
  const httpBridge = {
    akamata_fetch: suspending(async (rp, rl, op_addr, ol_addr) => {
      try {
        const s = readStr(rp, rl);
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
        const buf = exp.alloc(total);
        writeBytes(buf, headBytes);
        writeBytes(buf + headBytes.length, respBody);
        const dv = new DataView(memory.buffer);
        dv.setUint32(op_addr, buf, true);
        dv.setUint32(ol_addr, total, true);
        return 0;
      } catch (e) { console.error("akamata_fetch:", e?.message ?? e); return -2; }
    }),
  };

  const imports = { akamata_env: envBridge, akamata_d1: d1Bridge, akamata_http: httpBridge };
  instance = await WebAssembly.instantiate(wasm, imports);
  exp = instance.exports;
  memory = exp.memory;

  handleFetchAsync = (jspi && typeof exp.handle_fetch === "function")
    ? WebAssembly.promising(exp.handle_fetch)
    : (p, l) => exp.handle_fetch(p, l);

  if (typeof exp.akamata_init === "function") exp.akamata_init();
}

export default {
  async fetch(request, env, ctx) {
    await init(env);
    const url = new URL(request.url);
    const body = new Uint8Array(await request.arrayBuffer());
    const headers = [];
    for (const [k, v] of request.headers) headers.push(`${k}: ${v}`);
    const head = `${request.method} ${url.pathname}${url.search} HTTP/1.1\r\nhost: ${url.host}\r\n${headers.join("\r\n")}\r\ncontent-length: ${body.length}\r\n\r\n`;
    const headBytes = new TextEncoder().encode(head);
    const total = headBytes.length + body.length;
    const ptr = exp.alloc(total);
    writeBytes(ptr, headBytes);
    writeBytes(ptr + headBytes.length, body);
    const respPtr = await handleFetchAsync(ptr, total);
    const respLen = exp.last_response_length();
    if (respPtr === 0) { exp.dealloc(ptr, total); return new Response("internal error", { status: 500 }); }
    const respBytes = new Uint8Array(memory.buffer, respPtr, respLen).slice();
    exp.dealloc(ptr, total);
    exp.dealloc(respPtr, respLen);

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
    if (bytes[i] === 13 && bytes[i + 1] === 10 && bytes[i + 2] === 13 && bytes[i + 3] === 10) return i;
  }
  return -1;
}
