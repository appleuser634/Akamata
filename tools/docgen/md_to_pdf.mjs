#!/usr/bin/env node
// md_to_pdf.mjs — render a Markdown file to a paginated, print-styled PDF
// using `marked` for HTML conversion and a headless Chrome for rendering.
//
// Usage:
//   node md_to_pdf.mjs <input.md> <output.pdf> [--title=...] [--chrome=PATH]
//
// Dependencies:
//   - marked     Markdown → HTML (installed locally or via npx --yes)
//   - Chrome     macOS default at /Applications/Google Chrome.app/...
//                Override with --chrome=PATH or $CHROME_BIN.

import { marked } from "marked";
import { readFile, writeFile, mkdtemp, rm } from "node:fs/promises";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { join, basename, resolve } from "node:path";

const DEFAULT_CHROME =
  process.env.CHROME_BIN ||
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

function parseArgs(argv) {
  const [input, output, ...rest] = argv.slice(2);
  if (!input || !output) {
    console.error("usage: md_to_pdf.mjs <input.md> <output.pdf> [--title=...] [--chrome=PATH]");
    process.exit(64);
  }
  const opts = { title: null, chrome: DEFAULT_CHROME };
  for (const arg of rest) {
    if (arg.startsWith("--title=")) opts.title = arg.slice("--title=".length);
    else if (arg.startsWith("--chrome=")) opts.chrome = arg.slice("--chrome=".length);
  }
  return { input: resolve(input), output: resolve(output), ...opts };
}

const css = `
:root {
  --fg: #1a1a1a;
  --muted: #555;
  --accent: #2563eb;
  --code-bg: #f4f4f5;
  --code-fg: #1a1a1a;
  --border: #d4d4d8;
  --table-header: #f4f4f5;
}
@page {
  size: A4;
  margin: 18mm 16mm 22mm 16mm;
  @bottom-right { content: counter(page) " / " counter(pages); color: #888; font-size: 9pt; }
  @bottom-left  { content: string(doctitle); color: #888; font-size: 9pt; }
}
body {
  font-family: "Helvetica Neue", "Hiragino Sans", "Hiragino Kaku Gothic ProN",
               "Yu Gothic", Meiryo, sans-serif;
  font-size: 10.5pt;
  line-height: 1.55;
  color: var(--fg);
  margin: 0;
  string-set: doctitle attr(data-title);
}
h1, h2, h3, h4 {
  color: var(--fg);
  font-weight: 700;
  margin-top: 1.4em;
  margin-bottom: 0.3em;
  line-height: 1.25;
  page-break-after: avoid;
}
h1 { font-size: 22pt; border-bottom: 2px solid var(--accent); padding-bottom: 0.2em; }
h2 { font-size: 16pt; border-bottom: 1px solid var(--border); padding-bottom: 0.15em; margin-top: 1.8em; }
h3 { font-size: 13pt; }
h4 { font-size: 11pt; color: var(--muted); }
p { margin: 0.5em 0; }
hr { border: none; border-top: 1px solid var(--border); margin: 1.6em 0; }
a { color: var(--accent); text-decoration: none; }
ul, ol { padding-left: 1.4em; margin: 0.4em 0; }
li { margin: 0.15em 0; }
code {
  font-family: "JetBrains Mono", "SF Mono", Menlo, Consolas, monospace;
  font-size: 9.5pt;
  background: var(--code-bg);
  color: var(--code-fg);
  padding: 0.1em 0.35em;
  border-radius: 3px;
  border: 1px solid var(--border);
}
pre {
  background: var(--code-bg);
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: 0.6em 0.8em;
  overflow: auto;
  font-size: 9pt;
  line-height: 1.45;
  page-break-inside: avoid;
}
pre code {
  background: none;
  border: none;
  padding: 0;
  font-size: inherit;
}
blockquote {
  border-left: 3px solid var(--accent);
  margin: 0.8em 0;
  padding: 0.1em 0 0.1em 0.9em;
  color: var(--muted);
}
table {
  border-collapse: collapse;
  margin: 0.6em 0;
  font-size: 9.5pt;
  width: 100%;
}
table th, table td {
  border: 1px solid var(--border);
  padding: 0.35em 0.6em;
  text-align: left;
  vertical-align: top;
}
table th {
  background: var(--table-header);
  font-weight: 600;
}
h2, h3 { page-break-after: avoid; }
pre, table { page-break-inside: avoid; }
`;

function escapeHtml(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"
  }[c]));
}

function buildHtml(title, body) {
  return `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<title>${escapeHtml(title)}</title>
<style>${css}</style>
</head>
<body data-title="${escapeHtml(title)}">
${body}
</body>
</html>`;
}

async function runChromePrint(chrome, htmlPath, pdfPath) {
  return new Promise((resolve, reject) => {
    const proc = spawn(chrome, [
      "--headless=new",
      "--disable-gpu",
      "--no-pdf-header-footer",
      "--no-margins=false",
      `--print-to-pdf=${pdfPath}`,
      `file://${htmlPath}`,
    ], { stdio: ["ignore", "pipe", "pipe"] });
    let stderr = "";
    proc.stderr.on("data", (d) => { stderr += d.toString(); });
    proc.on("error", reject);
    proc.on("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`chrome exit ${code}\n${stderr}`));
    });
  });
}

function deriveTitle(md, path) {
  const firstH1 = md.match(/^#\s+(.+)$/m);
  if (firstH1) return firstH1[1].trim();
  return basename(path).replace(/\.[^.]+$/, "");
}

async function main() {
  const args = parseArgs(process.argv);
  const md = await readFile(args.input, "utf8");

  marked.use({ gfm: true, breaks: false });
  const bodyHtml = marked.parse(md);

  const title = args.title ?? deriveTitle(md, args.input);
  const html = buildHtml(title, bodyHtml);

  const tmp = await mkdtemp(join(tmpdir(), "akamata-pdf-"));
  try {
    const htmlPath = join(tmp, "doc.html");
    await writeFile(htmlPath, html, "utf8");
    await runChromePrint(args.chrome, htmlPath, args.output);
    console.log(`Wrote ${args.output}`);
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
}

main().catch((e) => {
  console.error(e.stack || String(e));
  process.exit(1);
});
