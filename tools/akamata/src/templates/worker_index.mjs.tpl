// Cloudflare Workers entry for the selected Akamata application, with D1/R2/
// Queue/Realtime support via JSPI.
//
// JSPI (JavaScript Promise Integration) lets async imports look synchronous
// to wasm/Zig: we wrap each D1 call with `new WebAssembly.Suspending(fn)` and
// wrap the wasm entry point with `WebAssembly.promising(handle_fetch)`. The
// V8 runtime parks the wasm stack across awaits and resumes it transparently.
//
// Net effect: Zig handlers call `db.prepare(...).step()` against D1 with the
// exact same code path used for SQLite/Turso.

import wasm from "../../zig-out/bin/akamata_worker.wasm";
import { WorkerEntrypoint } from "cloudflare:workers";
import { REALTIME_AUTHORIZE_PATH, REALTIME_MESSAGE_PATH, rejectPublicInternalRoute } from "./internal_routes.mjs";
import { WasmDispatchQueue } from "./wasm_dispatch.mjs";

let instance, memory, exports_ref, handleFetchAsync;
let instantiatePromise;
let jspi_supported = false;
const wasmDispatchQueue = new WasmDispatchQueue();

// === D1 statement registry ===
const d1stmts = new Map();
let nextStmtId = 1;
let lastD1Meta = { changes: 0, lastRowId: -1 };
const r2ops = new Map();
let nextR2Id = 1;
const r2lists = new Map();

function stmtRegistryAlloc(entry) {
  const id = nextStmtId++;
  d1stmts.set(id, entry);
  return id;
}

function readBytes(ptr, len) { return len === 0 ? new Uint8Array(0) : new Uint8Array(memory.buffer, ptr, len); }
function readString(ptr, len) { return new TextDecoder().decode(readBytes(ptr, len)); }
function writeBytes(ptr, bytes) { if (bytes.length > 0) new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes); }

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
  if (instantiatePromise) return instantiatePromise;
  instantiatePromise = instantiateOnce(env);
  try {
    await instantiatePromise;
  } catch (error) {
    instantiatePromise = undefined;
    throw error;
  }
}

async function instantiateOnce(env) {
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
    akamata_unix_micros() { return BigInt(Date.now()) * 1000n; },
    akamata_monotonic_ns() { return BigInt(Math.floor(performance.now() * 1_000_000)); },
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
    d1_column_is_null(h, idx) {
      const e = d1stmts.get(h);
      return !e || !e.currentRow || e.currentRow[idx] == null ? 1 : 0;
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
        const result = await d1.prepare(sql).run();
        lastD1Meta = {
          changes: Number(result?.meta?.changes ?? result?.meta?.rows_written ?? 0),
          lastRowId: Number(result?.meta?.last_row_id ?? -1),
        };
        return 0;
      } catch (e) {
        console.error("d1_exec failed:", e?.message ?? e);
        return -3;
      }
    }),
    d1_affected_rows() { return BigInt(lastD1Meta.changes); },
    d1_last_insert_id() { return BigInt(lastD1Meta.lastRowId); },
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

  const queueBridge = {
    akamata_queue_send: suspending(async (bindingPtr, bindingLen, metaPtr, metaLen, payloadPtr, payloadLen) => {
      const binding = readString(bindingPtr, bindingLen);
      const producer = env?.[binding];
      if (!producer || typeof producer.send !== "function") return -2;
      try {
        const metadata = JSON.parse(readString(metaPtr, metaLen));
        const payload = JSON.parse(readString(payloadPtr, payloadLen));
        await producer.send({ ...metadata, payload });
        return 0;
      } catch (error) {
        console.error(JSON.stringify({ message: "queue enqueue failed", binding, error: error instanceof Error ? error.message : String(error) }));
        return -1;
      }
    }),
  };

  const r2Bridge = {
    akamata_r2_put_begin: suspending(async (bindingPtr, bindingLen, keyPtr, keyLen, optionsPtr, optionsLen) => {
      const bucket = env?.[readString(bindingPtr, bindingLen)];
      if (!bucket?.put) return -2;
      try {
        const options = JSON.parse(readString(optionsPtr, optionsLen));
        const id = nextR2Id++;
        const putOptions = { httpMetadata: {}, customMetadata: {} };
        if (options.content_type) putOptions.httpMetadata.contentType = options.content_type;
        if (options.metadata_json) putOptions.customMetadata = JSON.parse(options.metadata_json);
        if (options.if_match) putOptions.onlyIf = { etagMatches: options.if_match };
        r2ops.set(id, { kind: "write", bucket, key: readString(keyPtr, keyLen), putOptions, chunks: [], size: 0 });
        return id;
      } catch { return -5; }
    }),
    akamata_r2_put_write: suspending(async (id, ptr, len) => {
      const op = r2ops.get(id); if (op?.kind !== "write") return -5;
      // dispatchWasm currently bounds the complete request body in WASM. Keep
      // the R2 bridge equally bounded and avoid a length-unknown stream, which
      // R2 rejects and can deadlock on TransformStream backpressure.
      if (op.size + len > 8 * 1024 * 1024) return -5;
      op.chunks.push(readBytes(ptr, len).slice()); op.size += len; return 0;
    }),
    akamata_r2_put_finish: suspending(async (id) => {
      const op = r2ops.get(id); if (op?.kind !== "write") return -5;
      try {
        const bytes = new Uint8Array(op.size);
        let offset = 0;
        for (const chunk of op.chunks) { bytes.set(chunk, offset); offset += chunk.length; }
        await op.bucket.put(op.key, bytes, op.putOptions);
        return 0;
      } catch { return -5; } finally { r2ops.delete(id); }
    }),
    akamata_r2_get_begin: suspending(async (bindingPtr, bindingLen, keyPtr, keyLen, offset, length, hasRange, optionsPtr, optionsLen) => {
      const bucket = env?.[readString(bindingPtr, bindingLen)];
      if (!bucket?.get) return -2;
      try {
        const options = JSON.parse(readString(optionsPtr, optionsLen));
        const getOptions = {};
        if (hasRange) getOptions.range = length > 0 ? { offset: Number(offset), length: Number(length) } : { offset: Number(offset) };
        if (options.if_match) getOptions.onlyIf = { etagMatches: options.if_match };
        if (options.if_none_match) getOptions.onlyIf = { etagDoesNotMatch: options.if_none_match };
        const object = await bucket.get(readString(keyPtr, keyLen), getOptions);
        if (!object) return -1;
        if (!object.body) return -3;
        const id = nextR2Id++;
        r2ops.set(id, {
          kind: "read", reader: object.body.getReader(), pending: new Uint8Array(0),
          size: Number(object.range?.length ?? object.size), etag: object.httpEtag ?? object.etag ?? "",
          contentType: object.httpMetadata?.contentType ?? "",
          customMetadata: JSON.stringify(object.customMetadata ?? {}),
        });
        return id;
      } catch { return -5; }
    }),
    akamata_r2_get_size(id) { return BigInt(r2ops.get(id)?.size ?? 0); },
    akamata_r2_get_etag(id, ptr, cap) { return copyR2String(r2ops.get(id)?.etag ?? "", ptr, cap); },
    akamata_r2_get_content_type(id, ptr, cap) { return copyR2String(r2ops.get(id)?.contentType ?? "", ptr, cap); },
    akamata_r2_get_custom_metadata(id, ptr, cap) { return copyR2String(r2ops.get(id)?.customMetadata ?? "", ptr, cap); },
    akamata_r2_get_read: suspending(async (id, outPtr, outCap) => {
      const op = r2ops.get(id); if (op?.kind !== "read") return -5;
      try {
        if (op.pending.length === 0) {
          const next = await op.reader.read();
          if (next.done) return 0;
          op.pending = next.value;
        }
        const n = Math.min(outCap, op.pending.length);
        writeBytes(outPtr, op.pending.subarray(0, n));
        op.pending = op.pending.subarray(n);
        return n;
      } catch { return -5; }
    }),
    akamata_r2_get_close(id) { const op = r2ops.get(id); if (op?.reader) op.reader.cancel().catch(() => {}); r2ops.delete(id); },
    akamata_r2_delete: suspending(async (bindingPtr, bindingLen, keyPtr, keyLen) => {
      const bucket = env?.[readString(bindingPtr, bindingLen)]; if (!bucket?.delete) return -2;
      try { await bucket.delete(readString(keyPtr, keyLen)); return 0; } catch { return -5; }
    }),
    akamata_r2_head: suspending(async (bindingPtr, bindingLen, keyPtr, keyLen) => {
      const bucket = env?.[readString(bindingPtr, bindingLen)]; if (!bucket?.head) return -2n;
      try { const object = await bucket.head(readString(keyPtr, keyLen)); return object ? BigInt(object.size) : -1n; } catch { return -5n; }
    }),
    akamata_r2_list_begin: suspending(async (bindingPtr, bindingLen, prefixPtr, prefixLen, cursorPtr, cursorLen, limit) => {
      const bucket = env?.[readString(bindingPtr, bindingLen)]; if (!bucket?.list) return -2;
      try {
        const options = { prefix: readString(prefixPtr, prefixLen), limit: Math.min(Number(limit), 1000) };
        const cursor = readString(cursorPtr, cursorLen); if (cursor) options.cursor = cursor;
        const page = await bucket.list(options);
        const encoded = new TextEncoder().encode(JSON.stringify(page.objects.map(o => ({ key: o.key, size: o.size, etag: o.httpEtag ?? o.etag ?? null }))));
        const id = nextR2Id++; r2lists.set(id, encoded); return id;
      } catch { return -5; }
    }),
    akamata_r2_list_len(id) { return r2lists.get(id)?.length ?? 0; },
    akamata_r2_list_copy(id, ptr, cap) { const bytes = r2lists.get(id); if (!bytes || bytes.length > cap) return -5; writeBytes(ptr, bytes); return bytes.length; },
    akamata_r2_list_close(id) { r2lists.delete(id); },
  };

  function copyR2String(value, ptr, cap) {
    const bytes = new TextEncoder().encode(value);
    if (bytes.length > cap) return -5;
    writeBytes(ptr, bytes);
    return bytes.length;
  }

  const imports = {
    akamata_env: envBridge,
    akamata_d1: d1Bridge,
    akamata_http: httpBridge,
    akamata_queue: queueBridge,
    akamata_r2: r2Bridge,
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
    await instantiate(env);

    const url = new URL(request.url);
    // These handlers are an application/DO control plane, never public HTTP
    // API. The DO reaches the message handler through the named entrypoint
    // service binding below.
    const rejected = rejectPublicInternalRoute(request);
    if (rejected) return rejected;
    const realtimeMatch = url.pathname.match(/^\/realtime\/([^/]+)$/);
    if (realtimeMatch && request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
      // The requested resource is only an authorization input. The client
      // never chooses the Durable Object key or logical identity directly.
      const resource = decodeURIComponent(realtimeMatch[1]);
      const authorization = request.headers.get("Authorization");
      if (!authorization || authorization.length > 8192) {
        return Response.json({ error: "unauthorized" }, { status: 401 });
      }
      const authUrl = new URL(REALTIME_AUTHORIZE_PATH, request.url);
      authUrl.searchParams.set("resource", resource);
      const authRequest = new Request(authUrl, {
        method: "POST",
        headers: { Authorization: authorization, Accept: "application/json" },
      });
      const authResponse = await dispatchWasm(authRequest);
      if (!authResponse.ok) {
        // Do not forward application diagnostics or credentials to the peer.
        return Response.json({ error: authResponse.status === 403 ? "forbidden" : "unauthorized" }, { status: authResponse.status === 403 ? 403 : 401 });
      }
      let authorized;
      try { authorized = await authResponse.json(); } catch { return Response.json({ error: "authorization_failed" }, { status: 500 }); }
      if (!isAuthorizedConnection(authorized)) return Response.json({ error: "authorization_failed" }, { status: 500 });
      const metadata = JSON.stringify(authorized.metadata ?? {});
      if (new TextEncoder().encode(metadata).byteLength > 4096) return Response.json({ error: "metadata_too_large" }, { status: 500 });
      const internal = new Headers();
      internal.set("Upgrade", "websocket");
      internal.set("X-Akamata-Connection-Id", crypto.randomUUID());
      internal.set("X-Akamata-Logical-Identity", authorized.logical_identity);
      internal.set("X-Akamata-Principal", JSON.stringify(authorized.principal));
      internal.set("X-Akamata-Metadata", metadata);
      internal.set("X-Akamata-Authorized", "1");
      const doRequest = new Request(request.url, { method: "GET", headers: internal });
      return env.AKAMATA_REALTIME.getByName(authorized.room).fetch(doRequest);
    }
    return dispatchWasm(request);
  },
  async queue(batch, env) {
    await instantiate(env);
    if (typeof exports_ref.handle_queue !== "function") {
      for (const message of batch.messages) message.retry();
      return;
    }
    const consume = jspi_supported ? WebAssembly.promising(exports_ref.handle_queue) : exports_ref.handle_queue;
    for (const message of batch.messages) {
      const bytes = new TextEncoder().encode(JSON.stringify({
        body: message.body,
        event_id: message.id,
        attempt: message.attempts,
        timestamp: message.timestamp.toISOString(),
      }));
      try {
        const rc = await wasmDispatchQueue.run(async () => {
          const ptr = exports_ref.alloc(bytes.length);
          writeBytes(ptr, bytes);
          try { return await consume(ptr, bytes.length); }
          finally { exports_ref.dealloc(ptr, bytes.length); }
        });
        if (rc === 0) message.ack(); else message.retry();
      } catch (error) {
        console.error(JSON.stringify({ message: "queue consumer failed", event_id: message.id, error: error instanceof Error ? error.message : String(error) }));
        message.retry();
      }
    }
  },
};

/// Service-binding-only control-plane entrypoint. Wrangler binds the Durable
/// Object to this named entrypoint; it is not addressable via the Worker's
/// public URL and accepts only the exact inbound-message contract.
export class AkamataRealtimeApplication extends WorkerEntrypoint {
  async fetch(request) {
    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== REALTIME_MESSAGE_PATH) {
      return Response.json({ error: "not_found" }, { status: 404 });
    }
    await instantiate(this.env);
    return dispatchWasm(request);
  }
}

async function dispatchWasm(request) {
  // JSPI can yield in handle_fetch. The Zig runtime exposes response length,
  // response storage, allocator state, and bridge registries on the shared
  // instance, so the entire ABI transaction must remain indivisible.
  return wasmDispatchQueue.run(() => dispatchWasmUnlocked(request));
}

async function dispatchWasmUnlocked(request) {
    const url = new URL(request.url);
  const bodyBuf = new Uint8Array(await request.arrayBuffer());
  const headers = [];
  // The synthetic HTTP/1 request owns Host and Content-Length. Workers
  // exposes Host in Request.headers, so forwarding it as well creates a
  // duplicate field that the strict Zig parser correctly rejects.
  for (const [k, v] of request.headers) {
    const lower = k.toLowerCase();
    if (lower === "host" || lower === "content-length") continue;
    headers.push(`${k}: ${v}`);
  }
    const head = `${request.method} ${url.pathname}${url.search} HTTP/1.1\r\nhost: ${url.host}\r\n${headers.join("\r\n")}\r\ncontent-length: ${bodyBuf.length}\r\n\r\n`;
    const headBytes = new TextEncoder().encode(head);
    const total = headBytes.length + bodyBuf.length;

    const ptr = exports_ref.alloc(total);
    writeBytes(ptr, headBytes);
    writeBytes(ptr + headBytes.length, bodyBuf);

    const respPtr = await handleFetchAsync(ptr, total);
    const respLen = exports_ref.last_response_length();
    if (respPtr === 0) {
      const errorLength = exports_ref.last_error_length?.() ?? 0;
      const errorName = errorLength > 0 ? readString(exports_ref.last_error_ptr(), errorLength) : "UnknownWasmDispatchError";
      console.error(JSON.stringify({ message: "akamata wasm dispatch failed", error: errorName }));
      exports_ref.dealloc(ptr, total);
      return new Response("internal error", { status: 500 });
    }
    const respBytes = new Uint8Array(memory.buffer, respPtr, respLen).slice();
    exports_ref.dealloc(ptr, total);
    exports_ref.dealloc(respPtr, respLen);

    return parseHttpResponse(respBytes);
}

function isAuthorizedConnection(value) {
  return value && typeof value === "object" &&
    typeof value.room === "string" && value.room.length > 0 && value.room.length <= 256 &&
    typeof value.logical_identity === "string" && value.logical_identity.length > 0 && value.logical_identity.length <= 256 &&
    value.principal && typeof value.principal === "object";
}

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
  if (!Number.isInteger(status) || status < 200 || status > 599) {
    return new Response("invalid wasm response status", { status: 502 });
  }
  return new Response(body, { status, headers });
}

function findHeaderEnd(bytes) {
  for (let i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] === 13 && bytes[i + 1] === 10 && bytes[i + 2] === 13 && bytes[i + 3] === 10) return i;
  }
  return -1;
}

export { AkamataRealtimeRoom } from "./realtime_object.mjs";
