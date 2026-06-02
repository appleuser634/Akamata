# tools/docgen — Markdown → PDF

Converts the framework's Markdown docs into print-styled PDFs.

## Usage

```bash
cd tools/docgen
npm install                  # one-time: pulls `marked`

npm run build                # regenerates everything (handbook + tutorial + slides)

# Or just one set:
npm run build:handbook       # docs/handbook(.ja).pdf
npm run build:tutorial       # docs/tutorial(.ja).pdf
npm run build:slides         # docs/slides(.ja).pdf
```

Or render any markdown file manually:

```bash
node md_to_pdf.mjs <input.md> <output.pdf> [--title=...] [--chrome=PATH]
node html_to_pdf.mjs <input.html> <output.pdf> [--chrome=PATH]
```

## Files

| Source | Output |
|---|---|
| `../../docs/handbook.md` | `../../docs/handbook.pdf` |
| `../../docs/handbook.ja.md` | `../../docs/handbook.ja.pdf` |
| `../../docs/tutorial.md` | `../../docs/tutorial.pdf` |
| `../../docs/tutorial.ja.md` | `../../docs/tutorial.ja.pdf` |
| `slides.html` (here) | `../../docs/slides.pdf` |
| `slides.ja.html` (here) | `../../docs/slides.ja.pdf` |

Slide decks live in `tools/docgen/` because they're hand-authored HTML (the
16:9 layout + page breaks aren't a good fit for Markdown). Markdown sources
for handbook/tutorial live next to the other docs in `../../docs/`.

## How it works

1. `marked` converts Markdown (GFM tables, fenced code) → HTML
2. We wrap it in an inline CSS template (A4, print-friendly typography,
   monospaced code blocks, page-numbered footer)
3. Headless Chrome's `--print-to-pdf` produces the final PDF.

The default Chrome path is the macOS `/Applications/Google Chrome.app/...`.
On Linux/CI set `CHROME_BIN` or pass `--chrome=/path/to/chrome`.

## Why this approach

- **No new toolchain**: every dev box has Chrome and Node already
- **Faithful rendering**: code blocks, tables, Japanese text all look correct
- **No LaTeX**: pandoc/xelatex are heavy to install and tune
- **No Puppeteer**: `--print-to-pdf` flag is enough; saves ~200MB of deps
