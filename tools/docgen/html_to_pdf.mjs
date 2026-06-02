#!/usr/bin/env node
// html_to_pdf.mjs — render a self-contained HTML file (already styled with
// `@page` rules) to PDF via headless Chrome. Used for slide decks where the
// markdown→HTML pipeline would lose page-break and 16:9 fidelity.
//
// Usage:
//   node html_to_pdf.mjs <input.html> <output.pdf> [--chrome=PATH]

import { spawn } from "node:child_process";
import { resolve } from "node:path";

const DEFAULT_CHROME =
  process.env.CHROME_BIN ||
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

function parseArgs(argv) {
  const [input, output, ...rest] = argv.slice(2);
  if (!input || !output) {
    console.error("usage: html_to_pdf.mjs <input.html> <output.pdf> [--chrome=PATH]");
    process.exit(64);
  }
  let chrome = DEFAULT_CHROME;
  for (const a of rest) {
    if (a.startsWith("--chrome=")) chrome = a.slice("--chrome=".length);
  }
  return { input: resolve(input), output: resolve(output), chrome };
}

async function run({ input, output, chrome }) {
  return new Promise((res, rej) => {
    const proc = spawn(chrome, [
      "--headless=new",
      "--disable-gpu",
      "--no-pdf-header-footer",
      `--print-to-pdf=${output}`,
      `file://${input}`,
    ], { stdio: ["ignore", "pipe", "pipe"] });
    let stderr = "";
    proc.stderr.on("data", (d) => { stderr += d.toString(); });
    proc.on("error", rej);
    proc.on("close", (code) => {
      if (code === 0) res();
      else rej(new Error(`chrome exit ${code}\n${stderr}`));
    });
  });
}

const args = parseArgs(process.argv);
await run(args);
console.log(`Wrote ${args.output}`);
