# Building documents

Every document compiles the same way on Overleaf and locally, with the settings in the project-root `latexmkrc`. Overleaf reads that file from the project root; `latexmk`, VimTeX included, reads the `latexmkrc` of the folder it starts in. Install pdfLaTeX, `latexmk`, and Biber, and Inkscape for SVG figures.

## What `latexmkrc` does

- **Shell escape**, for the `svg` package, which converts SVG figures with Inkscape.
- **Compiling in the source's folder** (`$do_cd`), so that a path such as `../figures/` resolves wherever `latexmk` is started.
- **Engine.** A document whose first lines say `% !TeX program = xelatex` (or `lualatex`) is compiled with that engine even when `latexmk` is asked for pdfLaTeX, as Overleaf and VimTeX ask by default. Slides in XeLaTeX and a paper in pdfLaTeX then share Overleaf's compiler setting, pdfLaTeX.
- **Cross-document references.** The manuscript imports the appendix's labels with `\externaldocument[][nocite]{appendix}` (package `xr`), and the appendix imports the manuscript's. Each reads the other's `.aux` file beside its source. `latexmk` compiles the other document first, in its own folder, when that `.aux` file is missing or the other document's `.tex` file has changed since. A document being compiled is never compiled again by the other, which reads the labels saved so far.
- **Combined document.** `combined.tex` attaches the two PDFs with `\includepdf`. Before `latexmk` looks at it, both documents are brought up to date.
- **Overleaf's file names**, described [below](#on-overleaf).

The other document is compiled again only when its own `.tex` file changes. An edit to a file it includes, a figure, or a table does not recompile it, and its PDF made along the way can show this document's labels as they were. Compile it directly to bring it up to date, or compile the combined document.

## Names and folders

The labels of a document are saved as `<name>.aux`, so the two documents need different names, and a label must be unique across both. After renaming a document, update its name in the other's `\externaldocument` line and in the `\includepdf` lines of the combined document. There is no other configuration.

Documents can live in a folder below the root, such as `draft/`. Keep `latexmkrc` at the root and add `draft/latexmkrc`, which loads it:

```perl
do '../latexmkrc'; die "Cannot load ../latexmkrc: $@\n" if $@;
```

A project with several such folders, for example `draft/` and `slides/`, gives each one the same line.

## On Overleaf

Choose the document as **Main document** in the project settings and leave the compiler on pdfLaTeX. Overleaf compiles every main document under the name `output`:

```sh
latexmk -cd -jobname=output -auxdir=DIR -outdir=DIR -pdf FOLDER/MAIN.tex
```

Before each compile, it deletes the generated files other than `output.*`, `*.aux`, and `*.pdf`. The settings allow for both:

- The labels of the document being compiled are also saved under its own name (`main.aux`), where the other document reads them.
- When the main document changes, the previous one's `output.*` files are removed first. Otherwise `latexmk` could show the previous document's PDF, and TeX would read its `.aux` file.
- A copy of the other document's `.aux` file in Overleaf's output folder, left by an older setup, is removed before each pass: TeX looks there first, so it would hide the current labels.

A compile after an edit costs that document's passes. The first compile of a document also compiles the other one. **Recompile from scratch**, in the Recompile menu, clears everything if a compile ever goes wrong.

Do not upload `.aux`, `.bbl`, or compiled PDF files into the project: Overleaf copies project files into every compile, over the files the compile makes. When the project syncs through Dropbox or Git, keep build files out of the sync.

## VimTeX and other editors

VimTeX compiles with `latexmk` by default and starts it in the root file's folder, so it reads the project's settings; nothing needs configuring. Keep the PDFs beside the sources, as VimTeX does by default and as Overleaf does. With `-outdir` (VimTeX's `out_dir`), the document being compiled goes to that folder, but the other document is still compiled beside its source.

Run one continuous compiler (`latexmk -pvc`, `:VimtexCompile`) per folder: it compiles the other document when needed and picks up edits to it. A second compiler in the same folder, for the other document, overwrites the same files. Switch documents by stopping the compiler (`:VimtexStop`) and starting it in the other document.

Do not add `-norc` or replace the pdfLaTeX command with `-pdflatex=...`: both bypass the settings.

## Figures and speed

pdfLaTeX copies a PNG's compressed data straight into the PDF only when nothing in the file has to be decoded. A `bKGD` (background colour) chunk is enough to make it decode and compress the whole image again, on every pass. R's `ragg` device, which `ggsave` uses for PNG, always writes one; with a few dozen large maps, a pass can take four times as long. Remove the chunk where the figures are made, or once over the figure folder:

```python
import pathlib, struct, sys
for path in pathlib.Path(sys.argv[1]).rglob('*.png'):
    data, out, i = path.read_bytes(), bytearray(), 8
    out += data[:8]
    while i < len(data):
        n = struct.unpack('>I', data[i:i + 4])[0]
        if data[i + 4:i + 8] != b'bKGD':
            out += data[i:i + 12 + n]
        i += 12 + n
    if len(out) < len(data):
        path.write_bytes(out)
```

The pixels do not change. XeLaTeX is not affected either way.

## Troubleshooting

- **`??` for a reference to the other document:** compile the other document, then this one. Its log shows why it failed, if it did. The first passes of a clean build can warn about such labels until the other document has compiled.
- **`xr: NAME.tex failed to compile; see NAME.log`:** the other document has an error. This document still compiles; once the error is fixed, the next compile of either document compiles it again.
- **A stale or wrong PDF on Overleaf:** **Recompile from scratch**.
- **Stale files locally:** stop the continuous compiler, then clean both documents and compile again. `-C` also removes the PDFs.

```sh
latexmk -C main.tex appendix.tex combined.tex
latexmk -pdf combined.tex
```

## Moving a paper from `gdt-build`

Papers set up with an earlier version of this template load `gdt-build.sty`, name their documents in `gdt-names.tex`, and may compile through root wrappers. To move one:

1. Replace its `latexmkrc` with this one, keeping any settings of the paper's own. For documents in a subfolder, add the loader described above.
2. In the manuscript, replace `\usepackage{gdt-build}` and `\GDTAppendixDocument` with `\usepackage{xr}` and `\externaldocument[][nocite]{<appendix name>}`. In the appendix, do the same with `\externaldocument[][nocite]{<manuscript name>}`.
3. In the combined document, remove `\usepackage{gdt-build}` and any `\GDTTrackDocument` lines, and write the two PDF names in the `\includepdf` lines.
4. Compile the documents in their own folder rather than through root wrappers, which the build no longer needs; a body that `\import`s nothing compiles as it is. Remove `\GDTBibliographyBase`, since bibliography paths are relative to the document again.
5. Delete `gdt-build.sty` and `gdt-names.tex` once nothing loads them, and the old build files (`latexmk -C`). On Overleaf, use **Recompile from scratch** once, and remove any build file that reached the project.

## Regression checks

Run `bash tests/test-build.sh`. It requires Bash, Python 3, `latexmk`, pdfLaTeX, and Poppler's `pdftotext` and `pdfinfo`. It builds small fixtures in temporary folders, never touching the repository's files, and checks:

- clean builds of each document under default and renamed names, with and without output and auxiliary folders and Overleaf's `output` job name, with the labels of both documents resolved and the combined pages in order;
- edits to an included source and to either document;
- that an edit compiles the other document only when its own source changed, and that a compile with no changes runs nothing;
- Overleaf's compile command, with its deletions between compiles, while the main document switches between the three, at the root and in a subfolder with a stale label file in the output folder;
- a continuous `latexmk -pvc` session following edits to the other document;
- a failing companion, then fixed, and a document with no companion;
- the XeLaTeX switch, when `xelatex` is installed, and the full sample with its bibliography, when Biber is.

Editors and hosted Overleaf need their own environments; the tests replay Overleaf's command and its file deletions.
