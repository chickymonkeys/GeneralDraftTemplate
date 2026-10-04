# General Draft Template

Copy this scaffold into each paper's project. The copy owns its dependencies: `preamble.sty`, `bibliography.sty`, `gdt-build.sty`, `gdt-names.tex`, and `latexmkrc`. Adjust paths in the manuscript and appendix sources for that project's figures, tables, and `.bib` file; there is no username or machine-specific path lookup. Changes to this repository are adopted manually by existing papers.

## Requirements and targets

Install TeX Live or MacTeX with pdfLaTeX, `latexmk`, and Biber. Install Inkscape on `PATH` if the paper uses SVG graphics. The build config enables shell escape for SVG conversion. From the directory containing `latexmkrc`, run any one of:

```sh
latexmk -pdf main.tex       # standalone manuscript
latexmk -pdf appendix.tex   # standalone appendix
latexmk -pdf combined.tex   # optional manuscript + appendix attachment
```

Both standalone documents import one another's labels. `latexmkrc` builds the companion automatically, including after auxiliary files are cleared, and lets `latexmk` run Biber. The optional combined target first ensures both PDFs are current. In Overleaf, select the desired root as the **Main document**, or open an independently compilable root and choose **Recompile**. VimTeX uses `latexmk` by default and reads the pdfLaTeX magic comment at the top of each target. See [Building documents](docs/building.md) for editor setup, output directories, wrappers, and troubleshooting.

## Choosing document filenames

Rename the three project-root entry files and update only their basenames in `gdt-names.tex` (omit `.tex`):

```tex
\def\GDTMainBase{paper-v2}
\def\GDTAppendixBase{online_appendix}
\def\GDTCombinedBase{submission.2026}
```

```sh
latexmk -pdf paper-v2.tex
latexmk -pdf online_appendix.tex
latexmk -pdf submission.2026.tex
latexmk -pdf -outdir=build paper-v2.tex
```

Names must start with a letter or digit, contain only ASCII letters, digits, hyphens, underscores, and internal dots, and be distinct ignoring case. Keep all entry files at project root. Update any literal `% !TeX root` comments in included sources, then restart/reselect the editor root. Existing labels and companion helpers need no changes. [The detailed guide](docs/building.md#configuration-grammar) gives the exact grammar and migration steps.

The bibliography uses standard `biblatex` author–year with AEA-oriented formatting and current AEA author-count limits, configured in `bibliography.sty`. It keeps `\citet`/`\citep` compatibility and does not print DOI/URL fields, which remain in the `.bib` file. It is not an official AEA style; `aea.bst` is retained for reference, not used by Biber.

`endfloat` is available but off by default. Set `\GDTEndfloattrue` immediately after loading `preamble` in `main.tex` to use it. The main and appendix sources should keep distinct filenames, since they produce distinct auxiliary files.

## Adapting a project with sources in a subdirectory

Overleaf recommends root-level main documents. Keep a thin root entry wrapper for each output, and put its basename in `gdt-names.tex`. Give each imported source a `% !TeX root = ../<entry-name>.tex` comment so VimTeX targets that wrapper while editing in `draft/`. Load the class only once. See the [paired wrapper examples](docs/building.md#nested-sources-and-root-wrappers), including bibliography-path handling; do not copy another paper's figure or table paths verbatim.
