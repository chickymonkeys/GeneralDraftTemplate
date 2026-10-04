# Building documents

The project owns `gdt-names.tex`, `latexmkrc`, `gdt-build.sty`, `preamble.sty`, and `bibliography.sty`. Keep them alongside the root entry files. Install pdfLaTeX, latexmk, and Biber; Inkscape is also needed for SVG conversion. The build callback enables shell escape. Run commands from the project root so latexmk reads the project configuration.

## Configuration grammar

The shipped mapping is:

```tex
\def\GDTMainBase{main}
\def\GDTAppendixBase{appendix}
\def\GDTCombinedBase{combined}
```

Each definition occupies one line, with exactly the literal spelling `\def\GDTMainBase{basename}`, `\def\GDTAppendixBase{basename}`, or `\def\GDTCombinedBase{basename}`. Each role must occur exactly once, in any order. Blank lines, leading/trailing whitespace, and `%` comments are accepted. There is no whitespace between `\def`, the macro name, and the braces, or inside the value. Additional TeX commands, macro expansion, `\newcommand`, multiline definitions, and multiple definitions on one line are rejected. Both TeX and Perl check this grammar; the file is read as literal data rather than executed as TeX code.

A basename starts with an ASCII letter or digit and continues with ASCII letters, digits, `-`, `_`, or dots. A final dot is forbidden. Equivalently, the value matches `[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9_-])?`. Omit the `.tex` extension. `paper-v2`, `online_appendix`, `submission.2026`, and `2nd-draft` are supported; spaces, slashes, backslashes, empty values, leading dots, trailing dots, and non-ASCII characters are not. Values must be distinct ignoring case, even on case-sensitive filesystems. Use project-root entry wrappers for nested sources; paths cannot be used as values.

All three definitions are required even if you do not use the optional combined output. A standalone build needs its configured companion source; a combined build needs both standalone sources. The combined source itself is only needed when you select that target.

## Renaming and migration

1. Rename the root entry files, for example `main.tex` → `paper-v2.tex`, `appendix.tex` → `online_appendix.tex`, and `combined.tex` → `submission.2026.tex`.
2. Set the three basenames in `gdt-names.tex` to `paper-v2`, `online_appendix`, and `submission.2026`.
3. Update literal `% !TeX root` comments on included sources. Restart the editor compiler and reselect the renamed root; change Overleaf's Main document selection too.
4. Build the chosen root. Existing label names stay unchanged.

```sh
latexmk -pdf paper-v2.tex
latexmk -pdf online_appendix.tex
latexmk -pdf submission.2026.tex
```

For an existing copy of the old scaffold, bring over `gdt-names.tex`, `gdt-build.sty`, and the updated `latexmkrc`, merging any project-specific rc settings. In the manuscript, replace `\GDTExternalDocument{appendix.tex}{appendix}` with `\GDTAppendixDocument`; in the appendix, replace `\GDTExternalDocument{main.tex}{main}` with `\GDTMainDocument`. Update the combined root to load `gdt-build`, call `\GDTTrackDocument{\GDTMainBase}` and `\GDTTrackDocument{\GDTAppendixBase}`, and include `\GDTMainBase.pdf` followed by `\GDTAppendixBase.pdf`. The generic two-argument `\GDTExternalDocument{source.tex}{aux-basename}` remains available for other external documents; it still imports labels without a prefix and with `nocite`.

## Source roles, output names, and synchronization

The source filename selects a role; `\jobname` does not. For example, `latexmk -pdf -jobname=output paper-v2.tex` selects the manuscript but writes `output.pdf` and `output.aux`. The callback synchronizes that auxiliary file to `paper-v2.aux` before and after each successful pdfLaTeX pass, where the appendix can find it. If the selected job's auxiliary file has disappeared, its stale canonical copy is removed before the companion is built. Companion jobs explicitly use their configured basenames, so that invocation still produces `online_appendix.pdf` and `online_appendix.aux`.

Standalone builds run their companion with `GDT_XR_COMPANION` set to prevent recursive companion spawning. latexmk handles each child's bibliography and reruns. The combined build starts a normal manuscript build, including its companion flow, so labels converge in both directions before the two PDFs are attached in manuscript–appendix order. Child failures fail the parent build. A source outside the three configured roles compiles normally without a companion.

The mapping file, companion entry source, imported auxiliary file, and companion recorder inputs are build dependencies. Reading the companion `.fls` registers included sources and graphics as well, so their edits can trigger a standalone or combined rebuild. Generated auxiliary inputs are excluded from that transitive source tracking. The callback reloads and validates the mapping on each pass, including in a live `latexmk -pvc` session. Changing a companion name can take effect during that session; renaming the selected root requires a restart/root reselection. Keep latexmk's recorder enabled.

## Output and auxiliary directories

```sh
latexmk -pdf -outdir=build paper-v2.tex
latexmk -pdf -outdir=build -jobname=output submission.2026.tex
latexmk -pdf -outdir=build -auxdir=auxiliary -emulate-aux-dir paper-v2.tex
```

Directory options are forwarded to children. With `-outdir=build`, PDFs and canonical auxiliaries live in `build/`. With separate directories, PDFs live in `build/`, canonical auxiliaries and recorder files in `auxiliary/`. On TeX Live, use latexmk's `-emulate-aux-dir` support (verified with latexmk 4.87); pdfLaTeX itself does not implement MiKTeX's separate aux-directory option. The callback exposes the final output directory to TeX's search path so the combined document can find companion PDFs even with separate auxiliary files. Preserve the project's existing `TEXINPUTS` settings.

Do not run concurrent builds with the same jobname and directories: two independently selected roots using `-jobname=output` share files. Stop the old compiler before selecting another root, or use separate build directories. The configured canonical names remain independent of the selected output jobname.

## VimTeX and LazyVim

Use VimTeX's latexmk compiler with project rc loading enabled. Keep `% !TeX program = pdflatex` at the top of each entry file and `% !TeX root = ../paper-v2.tex` (or the appendix wrapper name) on nested sources. Compile the configured entry root rather than an imported body directly. Do not add `-norc` or replace the project's pdfLaTeX command with `-pdflatex=...`, since those bypass the callback.

For a LazyVim configuration using `lervag/vimtex`, the following plugin specification illustrates the relevant settings; merge it into your own setup:

```lua
return {
  {
    "lervag/vimtex",
    lazy = false,
    init = function()
      vim.g.vimtex_compiler_method = "latexmk"
      vim.g.vimtex_compiler_latexmk = {
        out_dir = "build", -- use "" for outputs alongside the root
        options = {
          "-verbose", "-file-line-error", "-synctex=1",
          "-interaction=nonstopmode",
        },
      }
    end,
  },
}
```

VimTeX selects pdfLaTeX from the magic comment. latexmk reads `latexmkrc` from the project root automatically; keep that behavior enabled. If your editor launches latexmk elsewhere, arrange to run from the project root or explicitly load that rc with `-r /absolute/project/latexmkrc`. For a separate aux directory, set `aux_dir = "auxiliary"` alongside `out_dir = "build"`; current VimTeX forwards `-auxdir=auxiliary` and `-emulate-aux-dir` itself.

Open each configured root, run `:VimtexCompile`, and inspect `:VimtexInfo`: confirm the selected TeX root, latexmk compiler, build directory, and resulting PDF path. While editing a nested source, check that `:VimtexInfo` selects the wrapper named in its root comment. After renaming, stop the compiler (`:VimtexStop`), reopen/reselect the new root, and restart compilation. Clear stale files with `:VimtexClean` or the command-line cleanup described below when necessary. This guide does not change the user's editor configuration.

## Overleaf

Upload the entry files, `gdt-names.tex`, `latexmkrc`, style packages, bibliography, and other project inputs together. Keep the configured entry files at project root; Overleaf reads the project's `latexmkrc` after its system configuration. A server jobname such as `output` can differ from the selected source basename; canonical companion auxiliaries and PDFs still use the mapping.

1. Set **Main document** in project settings to `paper-v2.tex`, then **Recompile** for the standalone manuscript.
2. Select `online_appendix.tex` as Main document and recompile for the standalone appendix.
3. Select `submission.2026.tex` as Main document and recompile for the combined output. Its callback builds both standalone PDFs automatically.

Overleaf also allows recompiling an open independently compilable file containing a `\documentclass`; explicit Main document selection is clearest for wrappers. After a rename, update the setting and use **Recompile from scratch** from the Recompile menu if old cached auxiliaries persist. If compilation fails, inspect the child document's error in the build log rather than only the combined root's final error. Local `-jobname=output` tests emulate output naming; they do not substitute for a hosted Overleaf build.

## Nested sources and root wrappers

The configured basenames refer to these root wrappers, not to the imported body filenames. Here is a consistent renamed pair:

```tex
% paper-v2.tex (project root)
% !TeX program = pdflatex
\documentclass[11pt]{article}
\usepackage{import}
\def\GDTBibliographyBase{draft/}
\import{draft/}{manuscript-body.tex}
```

```tex
% online_appendix.tex (project root)
% !TeX program = pdflatex
\documentclass[11pt]{article}
\usepackage{import}
\def\GDTBibliographyBase{draft/}
\import{draft/}{appendix-body.tex}
```

```tex
% draft/manuscript-body.tex
% !TeX root = ../paper-v2.tex
\usepackage{preamble} % includes biblatex
\usepackage{gdt-build}
\GDTAppendixDocument
\addbibresource{../references/references.bib}
\begin{document}
% Manuscript content, including labels and references to appendix labels.
\end{document}
```

```tex
% draft/appendix-body.tex
% !TeX root = ../online_appendix.tex
\usepackage{preamble}
\usepackage{gdt-build}
\GDTMainDocument
\addbibresource{../references/references.bib}
\begin{document}
% Appendix content, including labels and references to manuscript labels.
\end{document}
```

Only the wrappers declare `\documentclass`. If retaining an existing body that can also compile directly, guard its class declaration with `\makeatletter\@ifundefined{ver@article.cls}{\documentclass[11pt]{article}}{}\makeatother` (adjust for the actual class). Do not leave an unconditional second class declaration in an imported body.

`\GDTBibliographyBase` is optional and must be defined before loading `gdt-build`, after biblatex is available. It prefixes each `\addbibresource` path because Biber resolves resources relative to the root entry file. In the example, `draft/` + `../references/references.bib` finds the project's `references/references.bib`. For bodies already using root-relative bibliography paths, omit the prefix. Keep the project styles at root or add the appropriate directory to `TEXINPUTS` in your project's rc. Adjust graphics and table paths for your own layout.

## Troubleshooting and clean rebuilds

- **Invalid or missing mapping:** check all three literal lines, their spelling, and the value grammar. Both direct pdfLaTeX and latexmk diagnose invalid mappings. An absent role or duplicate role is an error, not a request for a default.
- **Configured companion source is missing:** the mapping and filenames disagree. Rename the actual entry file or correct the value. Check case on case-sensitive systems.
- **References stay undefined:** ensure both sources load `gdt-build` and use the role helper, the referenced labels exist, and the child build succeeds. First child passes can warn about missing labels during a clean build; check the final PDFs. Imported labels have no prefix, so use distinct labels in the two documents.
- **Wrong output or old name:** verify the selected root in VimTeX/Overleaf. Changing the mapping does not rename files or change an editor's selected root. Stop the previous compiler when changing jobname or directories.
- **Included-source edits are missed:** keep `-recorder` enabled and the companion `.fls` files available. Rebuild once to refresh dependency lists after moving source files. The generic two-argument helper tracks only its specified entry source and auxiliary; use the role helpers for full template dependency tracking.
- **Stale auxiliaries:** clean both standalone jobs in the same directories/options used for compilation, then rebuild the selected root. If you used an overridden jobname, clean that job too. Stop continuous compilation first. `-C` removes generated PDFs as well, so use it only where those are disposable.

```sh
latexmk -C -outdir=build paper-v2.tex online_appendix.tex submission.2026.tex
latexmk -C -outdir=build -jobname=output paper-v2.tex
latexmk -pdf -outdir=build submission.2026.tex
```

When renaming, clean old jobs before moving their sources, or manually remove old generated auxiliaries (including the canonical `.aux` copy of a jobname override). Avoid deleting source files or figure PDFs. Direct pdfLaTeX validates the mapping and can import existing auxiliaries, but automatic companion generation, bibliography processing, synchronization, and convergence require latexmk.

## Regression checks

Run `bash tests/test-build.sh`. It requires Bash, Python 3, latexmk, pdfLaTeX with biblatex, and Poppler's `pdftotext`/`pdfinfo`. It builds lightweight fixtures in temporary directories, checks labels in both directions and combined page order, exercises default/renamed roots with canonical/overridden jobnames and output/auxiliary directories, edits sources and the live mapping, and checks failures and nested bibliography resource paths. It never copies the tracked sample PDFs. If Biber is on `PATH`, it also builds the full sample in a temporary copy; otherwise that check is explicitly skipped. Full-template compilation needs all packages used by `preamble.sty`; interactive editor and hosted Overleaf checks require those environments.
