# General Draft Template

Copy this scaffold into each paper's project. The copy owns its dependencies: `preamble.sty`, `bibliography.sty`, and `latexmkrc`. Adjust paths in the manuscript and appendix sources for that project's figures, tables, and `.bib` file; there is no username or machine-specific path lookup. Changes to this repository are adopted manually by existing papers.

## Requirements and targets

Install TeX Live or MacTeX with pdfLaTeX, `latexmk`, and Biber. Install Inkscape on `PATH` if the paper uses SVG graphics; `latexmkrc` enables shell escape for the conversion. From the project folder, run any one of:

```sh
latexmk -pdf main.tex       # standalone manuscript
latexmk -pdf appendix.tex   # standalone appendix
latexmk -pdf combined.tex   # the manuscript followed by the appendix, as one PDF
```

The manuscript and the appendix import each other's labels with the `xr` package (`\externaldocument`). `latexmkrc` compiles the other document first when its labels are missing or its `.tex` file has changed, so an edit to one document costs that document's passes alone. `latexmk` runs Biber. The combined target brings both PDFs up to date before attaching them.

The same `latexmkrc` works on Overleaf, which reads it from the project root: choose the document as **Main document** and leave the compiler on pdfLaTeX. VimTeX uses `latexmk` and reads the same file. See [Building documents](docs/building.md) for how it works, Overleaf, editors, and troubleshooting.

## Choosing document filenames

Rename the entry files freely, then update each name where another file uses it: the `\externaldocument` line of the other document and the `\includepdf` lines of the combined document. For example, with `paper-v2.tex`, `online_appendix.tex`, and `submission.tex`:

```tex
\externaldocument[][nocite]{online_appendix}   % in paper-v2.tex
\externaldocument[][nocite]{paper-v2}          % in online_appendix.tex
\includepdf[pages=-]{paper-v2.pdf}             % in submission.tex
\includepdf[pages=-]{online_appendix.pdf}
```

Each document needs a name of its own, since its labels are saved in `<name>.aux`, and labels must be unique across the two documents. Update any `% !TeX root` comments in included sources, then restart the editor's compiler and, on Overleaf, choose the new Main document.

The bibliography uses standard `biblatex` author–year with AEA-oriented formatting and current AEA author-count limits, configured in `bibliography.sty`. It keeps `\citet`/`\citep` compatibility and does not print DOI/URL fields, which remain in the `.bib` file. It is not an official AEA style; `aea.bst` is retained for reference, not used by Biber.

`endfloat` is available but off by default. Set `\GDTEndfloattrue` immediately after loading `preamble` in `main.tex` to use it.

## Documents in a subfolder

The entry files can live in a folder such as `draft/`, with figures and tables reached through `../`. Keep `latexmkrc` at the project root, where Overleaf reads it, and add `draft/latexmkrc` with one line that loads it, since `latexmk` reads the `latexmkrc` of the folder it starts in:

```perl
do '../latexmkrc'; die "Cannot load ../latexmkrc: $@\n" if $@;
```

Compile the documents in `draft/` directly; on Overleaf, choose `draft/main.tex` as Main document. No wrapper files are needed. Papers set up with an earlier version of this template can follow [the migration steps](docs/building.md#moving-a-paper-from-gdt-build).
