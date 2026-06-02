#!/usr/bin/env node
// http_fuzz.mjs — adversarial HTTP/1.1 client. Fires malformed and edge-case
// requests at a running server to check that it doesn't crash, leak, or
// return garbage. Designed for short runs (1-5 minutes) during CI / pre-deploy.
//
// What we test:
//   - giant payloads (Content-Length lying / huge bodies)
//   - chunked encoding edge cases (zero-size, bad hex, missing terminator)
//   - drip-feed sending (slowloris): one byte per second
//   - HTTP smuggling vectors (CL + TE, multiple CL, TE-not-chunked)
//   - illegal request line / methods / headers
//   - keep-alive abuse (request pipelining)
//   - reset mid-write
//   - random URL injection (control chars, NUL, %00)
//   - normal traffic mixed in to catch regressions
//
// Usage:
//   node http_fuzz.mjs http://127.0.0.1:8080 --duration=30s --workers=8
//
// Exit codes:
//   0  no crash detected; finished cleanly
//   1  server stopped accepting (likely crashed)
//   2  unexpected internal error in fuzzer

import net from "node:net";
import { URL } from "node:url";
import { argv, exit } from "node:process";

const args = parseArgs(argv.slice(2));
const baseUrl = new URL(args.target);
const host = baseUrl.hostname;
const port = parseInt(baseUrl.port || "80", 10);

const stats = {
  sent: 0,
  ok: 0,        // server replied with any complete HTTP response
  refused: 0,   // connect failed
  socket_err: 0,
  malformed_resp: 0,
  variants: {}, // count per attack variant
};

const variants = [
  giantContentLengthLie,
  hugeBodyButTinyCL,
  chunkedZeroSize,
  chunkedBadHex,
  chunkedNoTerminator,
  slowloris,
  smugglingCLTE,
  smugglingDuplicateCL,
  illegalMethod,
  illegalRequestLine,
  controlCharInUrl,
  nulByteInHeader,
  pipelinedBurst,
  resetMidWrite,
  normalGetMixedIn,
];

// === entry point ============================================================

async function main() {
  const deadline = Date.now() + args.durationMs;
  const workers = Array.from({ length: args.workers }, (_, i) => worker(i, deadline));
  await Promise.all(workers);
  printReport();
  // We treat "server still answering at the end" as success.
  const final = await checkStillAlive();
  if (!final) {
    console.error("[fuzz] FAIL: server stopped accepting connections");
    exit(1);
  }
  exit(0);
}

async function worker(id, deadline) {
  while (Date.now() < deadline) {
    const variant = variants[Math.floor(Math.random() * variants.length)];
    stats.variants[variant.name] = (stats.variants[variant.name] || 0) + 1;
    try {
      await variant();
    } catch (e) {
      // Per-attempt errors are fine; we only fail if the whole server dies.
      stats.socket_err++;
    }
  }
}

function printReport() {
  console.log("\n=== http_fuzz report ===");
  console.log("attempts:", stats.sent);
  console.log("complete responses:", stats.ok);
  console.log("connect refused:", stats.refused);
  console.log("socket errors:", stats.socket_err);
  console.log("malformed responses:", stats.malformed_resp);
  console.log("\nby variant:");
  for (const [k, v] of Object.entries(stats.variants).sort((a, b) => b[1] - a[1])) {
    console.log(`  ${k.padEnd(28)} ${v}`);
  }
}

async function checkStillAlive() {
  // One last normal request — server should still answer cleanly.
  try {
    const buf = await rawRequest(
      `GET / HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n`,
      { timeoutMs: 2000 }
    );
    return buf.toString("ascii").startsWith("HTTP/1.1 ");
  } catch {
    return false;
  }
}

// === fuzz variants ==========================================================

async function giantContentLengthLie() {
  // Server should reject or read up to limit, not allocate 10GB.
  await rawRequest(
    `POST /echo HTTP/1.1\r\nHost: ${host}\r\nContent-Length: 10737418240\r\n\r\n{}`,
    { timeoutMs: 800 }
  );
}

async function hugeBodyButTinyCL() {
  // Send 1MB body but advertise 4 bytes.
  const body = "X".repeat(1024 * 1024);
  await rawRequest(
    `POST /echo HTTP/1.1\r\nHost: ${host}\r\nContent-Length: 4\r\n\r\n${body}`,
    { timeoutMs: 1200 }
  );
}

async function chunkedZeroSize() {
  await rawRequest(
    `POST /echo HTTP/1.1\r\nHost: ${host}\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n`,
    { timeoutMs: 800 }
  );
}

async function chunkedBadHex() {
  await rawRequest(
    `POST /echo HTTP/1.1\r\nHost: ${host}\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n0\r\n\r\n`,
    { timeoutMs: 800 }
  );
}

async function chunkedNoTerminator() {
  await rawRequest(
    `POST /echo HTTP/1.1\r\nHost: ${host}\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello`,
    { timeoutMs: 800 }
  );
}

async function slowloris() {
  // Send headers one byte at a time, pausing between. Server should keep
  // working for other connections (we don't expect the slow request to
  // succeed; we only care that the server doesn't lock up).
  return new Promise((resolve) => {
    const sock = net.connect({ host, port });
    let sent = 0;
    const data = "GET / HTTP/1.1\r\nHost: " + host + "\r\nUser-Agent: ";
    const tick = setInterval(() => {
      if (sent >= data.length || sock.destroyed) {
        clearInterval(tick);
        sock.destroy();
        stats.sent++;
        resolve();
        return;
      }
      try { sock.write(data[sent]); } catch { /* ignore */ }
      sent++;
    }, 50);
    sock.on("error", () => { stats.socket_err++; });
    sock.setTimeout(2000, () => {
      clearInterval(tick);
      sock.destroy();
    });
  });
}

async function smugglingCLTE() {
  // Both Content-Length and Transfer-Encoding present.
  await rawRequest(
    `POST /echo HTTP/1.1\r\nHost: ${host}\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nfoo`,
    { timeoutMs: 800 }
  );
}

async function smugglingDuplicateCL() {
  await rawRequest(
    `POST /echo HTTP/1.1\r\nHost: ${host}\r\nContent-Length: 4\r\nContent-Length: 8\r\n\r\nabcd1234`,
    { timeoutMs: 800 }
  );
}

async function illegalMethod() {
  await rawRequest(
    `🦀ATCH / HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n`,
    { timeoutMs: 800 }
  );
}

async function illegalRequestLine() {
  await rawRequest(
    `GET   /   HTTP/9.99\r\nHost: ${host}\r\nConnection: close\r\n\r\n`,
    { timeoutMs: 800 }
  );
}

async function controlCharInUrl() {
  await rawRequest(
    `GET /\x01\x02\x03 HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n`,
    { timeoutMs: 800 }
  );
}

async function nulByteInHeader() {
  await rawRequest(
    `GET / HTTP/1.1\r\nHost: ${host}\r\nX-Bad: a\x00b\r\nConnection: close\r\n\r\n`,
    { timeoutMs: 800 }
  );
}

async function pipelinedBurst() {
  // Send 5 valid requests back-to-back, then read.
  const one = `GET / HTTP/1.1\r\nHost: ${host}\r\n\r\n`;
  await rawRequest(one.repeat(5) + `GET / HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n`, {
    timeoutMs: 1500,
  });
}

async function resetMidWrite() {
  // Open, send half a request, RST.
  return new Promise((resolve) => {
    const sock = net.connect({ host, port });
    sock.on("connect", () => {
      sock.write("GET /hello HTTP/1.1\r\nHost: ");
      // No linger -> RST on destroy()
      sock.resetAndDestroy();
      stats.sent++;
      resolve();
    });
    sock.on("error", () => { stats.socket_err++; resolve(); });
    sock.setTimeout(800, () => { sock.destroy(); resolve(); });
  });
}

async function normalGetMixedIn() {
  // Sanity request — should succeed normally, proving the server is still
  // healthy after the abuse.
  const buf = await rawRequest(
    `GET / HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n`,
    { timeoutMs: 1000 }
  );
  if (buf.toString("ascii").startsWith("HTTP/1.1 ")) stats.ok++;
  else stats.malformed_resp++;
}

// === low-level TCP helper ===================================================

function rawRequest(payload, opts = {}) {
  return new Promise((resolve, reject) => {
    const sock = net.connect({ host, port });
    const timeoutMs = opts.timeoutMs ?? 1500;
    const chunks = [];
    sock.on("connect", () => {
      sock.write(payload);
    });
    sock.on("data", (d) => chunks.push(d));
    sock.on("error", (e) => {
      if (e.code === "ECONNREFUSED") stats.refused++;
      else stats.socket_err++;
      reject(e);
    });
    sock.on("close", () => {
      stats.sent++;
      resolve(Buffer.concat(chunks));
    });
    sock.setTimeout(timeoutMs, () => {
      sock.destroy();
    });
  });
}

// === args ===================================================================

function parseArgs(av) {
  const opts = { target: "http://127.0.0.1:8080", durationMs: 30_000, workers: 8 };
  for (const a of av) {
    if (a.startsWith("--duration=")) {
      const s = a.slice("--duration=".length);
      const m = s.match(/^(\d+)(ms|s|m)?$/);
      if (!m) throw new Error("bad --duration");
      const n = parseInt(m[1], 10);
      const unit = m[2] ?? "s";
      opts.durationMs = unit === "ms" ? n : unit === "m" ? n * 60_000 : n * 1000;
    } else if (a.startsWith("--workers=")) {
      opts.workers = parseInt(a.slice("--workers=".length), 10);
    } else if (a.startsWith("http://") || a.startsWith("https://")) {
      opts.target = a;
    }
  }
  return opts;
}

main().catch((e) => { console.error("[fuzz] uncaught:", e); exit(2); });
