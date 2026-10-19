#!/usr/bin/env bash
# Real builds in disposable projects; no repository PDFs or auxiliaries copied.
set -euo pipefail
repo="$(dirname "$(dirname "$(realpath "$0")")")"
exec python3 - "$repo" <<'PY'
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

repo = pathlib.Path(sys.argv[1])
for tool in ('latexmk', 'pdflatex', 'pdftotext', 'pdfinfo'):
    if not shutil.which(tool):
        sys.exit(f'Required test tool missing: {tool}')
NAMES = ('main', 'appendix', 'combined')
RENAMED = ('paper-v2', 'online_appendix', 'submission.2026')
LOADER = 'do \'../latexmkrc\'; die "Cannot load ../latexmkrc: $@\\n" if $@;\n'


def run(project, args, ok=True):
    result = subprocess.run(args, cwd=project, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=180)
    if (result.returncode == 0) != ok:
        logs = '\n'.join(f'{f}:\n{f.read_text(errors="replace")}' for f in project.rglob('*.log'))
        raise AssertionError(f'{project}: {args}\n{result.stdout}\n{logs}')
    return result.stdout


def fixture(project, names=NAMES, folder=''):
    # The three entry files in project/folder, the repository's latexmkrc at the
    # root and, for a folder, the latexmkrc that loads it.
    source = project / folder
    source.mkdir(parents=True)
    shutil.copyfile(repo / 'latexmkrc', project / 'latexmkrc')
    if folder:
        (source / 'latexmkrc').write_text(LOADER)
    main, appendix, combined = names
    for role, name, other in (('main', main, appendix), ('appendix', appendix, main)):
        text = (repo / 'tests/fixtures' / f'{role}.tex').read_text()
        text = text.replace('{appendix}' if role == 'main' else '{main}', f'{{{other}}}')
        (source / f'{name}.tex').write_text(text)
    shutil.copyfile(repo / 'tests/fixtures/body.tex', source / 'body.tex')
    text = (repo / 'combined.tex').read_text()
    text = text.replace('{main.pdf}', f'{{{main}.pdf}}').replace('{appendix.pdf}', f'{{{appendix}.pdf}}')
    (source / f'{combined}.tex').write_text(text)
    return source


def build(source, name, options=(), ok=True):
    return run(source, ['latexmk', '-pdf', '-silent', '-interaction=nonstopmode',
                        '-halt-on-error', *options, f'{name}.tex'], ok)


def text(pdf):
    return run(pdf.parent, ['pdftotext', str(pdf), '-'])


def pages(pdf):
    return int(re.search(r'^Pages:\s+(\d+)', run(pdf.parent, ['pdfinfo', str(pdf)]), re.M)[1])


def resolved(pdf, role, manuscript=1, appendix=7):
    content = text(pdf)
    if role in ('main', 'combined'):
        assert f'Appendix reference: {appendix}.' in content, (pdf, content)
    if role in ('appendix', 'combined'):
        assert f'Manuscript reference: {manuscript}.' in content, (pdf, content)
    if role == 'combined':
        assert content.index('MANUSCRIPT-FIRST') < content.index('APPENDIX-SECOND')
        assert pages(pdf) == 2


def set_appendix_section(source, name, number):
    path = source / f'{name}.tex'
    path.write_text(re.sub(r'\\setcounter\{section\}\{\d+\}',
                           lambda _: f'\\setcounter{{section}}{{{number - 1}}}', path.read_text()))


def files(project):
    return {p.relative_to(project).as_posix() for p in project.rglob('*') if p.is_file()}


def overleaf(project, sources, main):
    # Overleaf's compile: first delete the generated files other than output.*,
    # *.aux and *.pdf, then run its latexmk command from the project root.
    for relative in files(project) - sources:
        if not (relative.startswith(('output.', 'output-', 'cache/'))
                or relative.endswith(('.aux', '.pdf'))):
            (project / relative).unlink()
    return run(project, ['latexmk', '-cd', '-jobname=output', f'-auxdir={project}',
                         f'-outdir={project}', '-synctex=1', '-interaction=batchmode',
                         '-f', '-pdf', main])


with tempfile.TemporaryDirectory(prefix='gdt-build-') as tmp:
    root = pathlib.Path(tmp)

    count = 0
    for names in (NAMES, RENAMED):
        for role, name in zip(NAMES, names):
            for out, options in [('.', []), ('build', ['-outdir=build']),
                                 ('build', ['-outdir=build', '-auxdir=auxiliary', '-emulate-aux-dir'])]:
                for job in (None, 'output'):
                    count += 1
                    source = fixture(root / str(count), names)
                    build(source, name, options + ([f'-jobname={job}'] if job else []))
                    resolved(source / out / f'{job or name}.pdf', role)
                    # The other documents are compiled beside their sources.
                    for other_role, other in zip(('main', 'appendix'), names):
                        if other != name:
                            resolved(source / f'{other}.pdf', other_role)
        print(f'PASS: clean builds named {", ".join(names)}', flush=True)
    print(f'PASS: {count} clean document/name/directory/jobname combinations', flush=True)

    source = fixture(root / 'edits', RENAMED)
    main, appendix, combined = RENAMED
    build(source, combined)
    (source / 'body.tex').write_text((source / 'body.tex').read_text().replace(
        '\\section', '\\setcounter{section}{2}\n\\section'))
    build(source, combined)
    resolved(source / f'{combined}.pdf', 'combined', manuscript=3)
    set_appendix_section(source, appendix, 9)
    build(source, main)
    resolved(source / f'{main}.pdf', 'main', appendix=9)
    build(source, combined)
    resolved(source / f'{combined}.pdf', 'combined', manuscript=3, appendix=9)
    print('PASS: included-source and bidirectional label edits', flush=True)

    source = fixture(root / 'incremental')
    build(source, 'main')
    companion = (source / 'appendix.pdf').stat().st_mtime_ns
    output = build(source, 'main')
    assert 'xr:' not in output and 'Run number' not in output, output
    (source / 'body.tex').write_text((source / 'body.tex').read_text() + 'More text.\n')
    output = build(source, 'main')
    assert 'xr:' not in output and (source / 'appendix.pdf').stat().st_mtime_ns == companion, output
    set_appendix_section(source, 'appendix', 9)
    assert 'xr: compiling appendix.tex' in build(source, 'main')
    resolved(source / 'main.pdf', 'main', appendix=9)
    print('PASS: a document compiles the other only when the other\'s source changes', flush=True)

    for folder in ('', 'draft'):
        project = root / f'overleaf-{folder or "root"}'
        source = fixture(project, folder=folder)
        sources = files(project)
        prefix = f'{folder}/' if folder else ''
        if folder:
            # Labels of the other document left in the output folder by an
            # older setup must not hide the current ones.
            (project / 'appendix.aux').write_text('\\relax\n\\newlabel{app:result}{{99}{1}}\n')
        output_pdf = project / 'output.pdf'
        overleaf(project, sources, f'{prefix}main.tex')
        resolved(output_pdf, 'main')
        output = overleaf(project, sources, f'{prefix}main.tex')
        assert 'xr:' not in output and 'Run number' not in output, output
        for role in ('appendix', 'combined', 'main'):
            overleaf(project, sources, f'{prefix}{role}.tex')
            resolved(output_pdf, role)
        set_appendix_section(source, 'appendix', 9)
        overleaf(project, sources, f'{prefix}main.tex')
        resolved(output_pdf, 'main', appendix=9)
        # The same project compiles locally, from the documents' folder.
        build(source, 'combined')
        resolved(source / 'combined.pdf', 'combined', appendix=9)
        print(f'PASS: Overleaf compiles and main-document switches, {folder or "root"} folder', flush=True)

    source = fixture(root / 'continuous')
    log = (source / 'continuous.txt').open('w')
    proc = subprocess.Popen(['latexmk', '-pdf', '-pvc', '-view=none', '-silent',
                             '-interaction=nonstopmode', 'main.tex'],
                            cwd=source, stdout=log, stderr=subprocess.STDOUT)

    def wait_for(expected):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline and proc.poll() is None:
            pdf = source / 'main.pdf'
            if pdf.exists() and expected in text(pdf):
                return
            time.sleep(0.5)
        raise AssertionError(f'continuous build never showed {expected!r}:\n'
                             + (source / 'continuous.txt').read_text())

    try:
        wait_for('Appendix reference: 7.')
        set_appendix_section(source, 'appendix', 9)
        wait_for('Appendix reference: 9.')
    finally:
        proc.terminate()
        proc.wait(timeout=15)
        log.close()
    print('PASS: a continuous build follows edits to the other document', flush=True)

    source = fixture(root / 'failures')
    path = source / 'appendix.tex'
    good = path.read_text()
    path.write_text(good.replace('APPENDIX-SECOND', 'APPENDIX-SECOND \\undefinedcommand'))
    assert 'xr: appendix.tex failed to compile' in build(source, 'main')
    path.write_text(good)
    assert 'xr: compiling appendix.tex' in build(source, 'main')
    resolved(source / 'main.pdf', 'main')
    resolved(source / 'appendix.pdf', 'appendix')
    source = fixture(root / 'unrelated')
    (source / 'other.tex').write_text('\\documentclass{article}\n\\begin{document}Other\\end{document}\n')
    assert 'xr:' not in build(source, 'other')
    assert not (source / 'main.pdf').exists() and not (source / 'appendix.pdf').exists()
    print('PASS: a failing companion, then fixed; a document without companions', flush=True)

    if shutil.which('xelatex'):
        source = fixture(root / 'engine')
        (source / 'slides.tex').write_text('% !TeX program = xelatex\n\\documentclass{article}\n'
                                           '\\begin{document}Slides\\end{document}\n')
        build(source, 'slides')
        assert 'XeTeX' in (source / 'slides.log').read_text()
        print('PASS: the TeX program comment selects XeLaTeX', flush=True)
    else:
        print('SKIP: engine selection (XeLaTeX is not on PATH)', flush=True)

    if shutil.which('biber'):
        project = root / 'full-sample'
        project.mkdir()
        tracked = run(repo, ['git', 'ls-files', '-z']).split('\0')
        for name in tracked:
            if not name or name in ('main.pdf', 'appendix.pdf', 'combined.pdf'):
                continue
            path = repo / name
            if path.is_file():
                target = project / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, target)
        build(project, 'combined')
        for name in ('main', 'appendix'):
            log = (project / f'{name}.log').read_text(errors='replace')
            assert not re.search(r"(Reference|Citation) `[^']+' on page \d+ undefined", log), name
        assert pages(project / 'combined.pdf') == pages(project / 'main.pdf') + pages(project / 'appendix.pdf')
        print('PASS: full sample including Biber', flush=True)
    else:
        print('SKIP: full sample bibliography build (Biber is not on PATH)', flush=True)
print('All build regressions passed.')
PY
