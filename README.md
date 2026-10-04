# General Draft Template

Copy this scaffold into each paper's project. The copy owns its dependencies: `preamble.sty`, `aea-bibliography.sty`, `gdt-build.sty`, and `latexmkrc`. Adjust paths in `main.tex` and `appendix.tex` for that project's figures, tables, and `.bib` file; there is no username or machine-specific path lookup. Changes to this repository are adopted manually by existing papers.

## Requirements and targets

Install TeX Live or MacTeX with pdfLaTeX, `latexmk`, and Biber. Install Inkscape on `PATH` if the paper uses SVG graphics. The build config enables shell escape for SVG conversion. From the directory containing `latexmkrc`, run any one of:

```sh
latexmk -pdf main.tex       # standalone manuscript
latexmk -pdf appendix.tex   # standalone appendix
latexmk -pdf combined.tex   # optional manuscript + appendix attachment
```

Both standalone documents import one another's labels. `latexmkrc` builds the companion automatically, including after auxiliary files are cleared, and lets `latexmk` run Biber. The optional combined target first ensures both PDFs are current. Opening one of these three root files in Overleaf and choosing **Recompile** selects that output. VimTeX uses `latexmk` by default and reads the pdfLaTeX magic comment at the top of each target.

The bibliography uses standard `biblatex` author–year with AEA-oriented formatting and current AEA author-count limits, configured in `aea-bibliography.sty`. It keeps `\citet`/`\citep` compatibility and does not print DOI/URL fields, which remain in the `.bib` file. It is not an official AEA style; `aea.bst` is retained for reference, not used by Biber.

`endfloat` is available but off by default. Set `\GDTEndfloattrue` immediately after loading `preamble` in `main.tex` to use it. The main and appendix sources should keep distinct filenames, since they produce distinct auxiliary files.

## Adapting a project with sources in a subdirectory

Overleaf recommends root-level main documents. Keep a thin root entry file for each output; the root `main.tex` can contain a `\documentclass` followed by `\RequirePackage{import}` and `\import{draft/}{your-main.tex}`. Give the imported source a `% !TeX root = ../main.tex` comment so VimTeX targets the same entry file while editing in `draft/`. A root-level `latexmkrc` can add `draft/` to `TEXINPUTS` to discover local `.sty` files. If the imported source also declares its class for direct use, guard its `\documentclass` so only one class loads when imported. See the paper project's own path configuration for its chosen folder layout; do not copy its figure or table paths verbatim.
