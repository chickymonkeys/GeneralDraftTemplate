#!/usr/bin/env bash
# Real builds in disposable projects; no repository PDFs or auxiliaries copied.
set -euo pipefail
repo="$(dirname "$(dirname "$(realpath "$0")")")"
exec python3 - "$repo" <<'PY'
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

repo = pathlib.Path(sys.argv[1])
for tool in ('latexmk', 'pdflatex', 'pdftotext', 'pdfinfo'):
    if not shutil.which(tool):
        sys.exit(f'Required test tool missing: {tool}')


def run(project, args, ok=True):
    result = subprocess.run(args, cwd=project, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=90)
    if (result.returncode == 0) != ok:
        logs = '\n'.join(f'{f}:\n{f.read_text(errors="replace")}' for f in project.rglob('*.log'))
        raise AssertionError(f'{project}: {args}\n{result.stdout}\n{logs}')
    return result.stdout


def config(project, names):
    (project / 'gdt-names.tex').write_text(''.join(
        f'\\def\\GDT{role}Base{{{name}}}\n'
        for role, name in zip(('Main', 'Appendix', 'Combined'), names)))


def fixture(project, names):
    project.mkdir()
    for file in ('latexmkrc', 'gdt-build.sty', 'combined.tex'):
        shutil.copyfile(repo / file, project / file)
    (project / 'combined.tex').rename(project / f'{names[2]}.tex')
    for role, name in zip(('main', 'appendix'), names):
        shutil.copyfile(repo / 'tests/fixtures' / f'{role}.tex', project / f'{name}.tex')
    shutil.copyfile(repo / 'tests/fixtures/body.tex', project / 'body.tex')
    config(project, names)


def build(project, name, options=(), ok=True):
    return run(project, ['latexmk', '-pdf', '-silent', '-interaction=nonstopmode',
                         '-halt-on-error', *options, f'{name}.tex'], ok)


def text(project, file):
    return run(project, ['pdftotext', str(file), '-'])


def resolved(project, names, out='.', aux='.', job=None, role=0):
    selected = job or names[role]
    # The selected standalone may have a noncanonical PDF name, but labels
    # must always be exported under the configured source-role basename.
    for i in (0, 1):
        pdf = selected if role == i else names[i]
        content = text(project, f'{out}/{pdf}.pdf')
        assert ('Appendix reference: 7.' if i == 0 else 'Manuscript reference: 1.') in content, content
        assert f'\\newlabel{{{("main", "app")[i]}:result}}' in (project / aux / f'{names[i]}.aux').read_text()
    if role == 2:
        content = text(project, f'{out}/{selected}.pdf')
        assert content.index('MANUSCRIPT-FIRST') < content.index('APPENDIX-SECOND')
        assert 'Pages:           2' in run(project, ['pdfinfo', f'{out}/{selected}.pdf'])


with tempfile.TemporaryDirectory(prefix='gdt-build-') as tmp:
    root = pathlib.Path(tmp)
    variants = [('main', 'appendix', 'combined'),
                ('paper-v2', 'online_appendix', 'submission.2026')]
    count = 0
    for names in variants:
        for role in range(3):
            for out, aux, options in [('.', '.', []), ('build', 'build', ['-outdir=build']),
                                      ('build', 'auxiliary', ['-outdir=build', '-auxdir=auxiliary', '-emulate-aux-dir'])]:
                for job in (None, 'output'):
                    count += 1
                    p = root / str(count)
                    fixture(p, names)
                    flags = options + ([f'-jobname={job}'] if job else [])
                    build(p, names[role], flags)
                    resolved(p, names, out, aux, job, role)
                    assert 'gdt-names.tex' in (p / aux / f'{job or names[role]}.fls').read_text()
                    if names == variants[1]:
                        assert not (p / 'main.tex').exists() and not (p / 'appendix.tex').exists()
            print(f'PASS: clean {names[role]} builds', flush=True)
    print(f'PASS: {count} clean role/name/directory/jobname combinations', flush=True)

    p = root / 'edits'
    names = variants[1]
    fixture(p, names)
    build(p, names[2])
    (p / 'body.tex').write_text('\\setcounter{section}{2}\n\\section{Changed}\\label{main:result}\nMANUSCRIPT-FIRST\n')
    build(p, names[2])
    assert 'Manuscript reference: 3.' in text(p, f'{names[1]}.pdf')
    app = p / f'{names[1]}.tex'
    app.write_text(app.read_text().replace('{6}', '{8}'))
    build(p, names[0])
    assert 'Appendix reference: 9.' in text(p, f'{names[0]}.pdf')
    build(p, names[2])
    assert 'Appendix reference: 9.' in text(p, f'{names[2]}.pdf')
    print('PASS: included-source and bidirectional label edits', flush=True)

    # Keep a live callback process; config edits must be noticed without rc reload.
    p = root / 'continuous'
    fixture(p, variants[0])
    log = (p / 'continuous.txt').open('w')
    proc = subprocess.Popen(['latexmk', '-pdf', '-pvc', '-view=none', '-silent',
                             '-interaction=nonstopmode', '-halt-on-error', 'main.tex'],
                            cwd=p, stdout=log, stderr=subprocess.STDOUT)

    def wait_for(predicate):
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if predicate():
                return
            if proc.poll() is not None:
                break
            time.sleep(0.3)
        raise AssertionError((p / 'continuous.txt').read_text())

    def live_pdf_contains(expected):
        # pdfLaTeX truncates the PDF while writing a new pass. A temporarily
        # empty/incomplete stream is not a failed continuous build.
        result = subprocess.run(['pdftotext', 'main.pdf', '-'], cwd=p, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        return result.returncode == 0 and expected in result.stdout

    try:
        wait_for(lambda: live_pdf_contains('Appendix reference: 7.'))
        # Change a companion role while leaving the selected root in place.
        shutil.copyfile(p / 'appendix.tex', p / 'new-app.tex')
        new_app = p / 'new-app.tex'
        new_app.write_text(new_app.read_text().replace('{6}', '{10}'))
        config(p, ('main', 'new-app', 'combined'))
        wait_for(lambda: (p / 'new-app.pdf').exists() and
                 live_pdf_contains('Appendix reference: 11.'))
    finally:
        proc.terminate()
        proc.wait(timeout=15)
        log.close()
    print('PASS: live mapping reload and dependency tracking', flush=True)

    invalid = [('', 'missing'),
               ('\\def\\GDTMainBase{main}\n' * 2, 'duplicate'),
               ('\\def\\GDTMainBase{bad name}\n', 'invalid'),
               ('\\def\\GDTMainBase{path/main}\n', 'invalid'),
               ('\\def\\GDTMainBase{main.}\n', 'invalid'),
               ('\\def\\GDTMainBase{}\n', 'invalid'),
               ('\\def\\GDTMainBase{\\jobname}\n', 'invalid'),
               ('\\def\\GDTMainBase{Main}\n\\def\\GDTAppendixBase{main}\n\\def\\GDTCombinedBase{combined}\n', 'distinct')]
    for i, (content, error) in enumerate(invalid):
        p = root / f'invalid-{i}'
        fixture(p, variants[0])
        (p / 'gdt-names.tex').write_text(content)
        assert error in build(p, 'main', ok=False)
        output = run(p, ['pdflatex', '-interaction=nonstopmode', '-halt-on-error', 'main.tex'], False)
        assert 'Invalid gdt-names.tex' in output, output
    p = root / 'missing-config'
    fixture(p, variants[0])
    (p / 'gdt-names.tex').unlink()
    assert 'cannot read' in build(p, 'main', ok=False)
    assert 'file missing' in run(p, ['pdflatex', '-interaction=nonstopmode', '-halt-on-error', 'main.tex'], False)
    p = root / 'missing-source'
    fixture(p, variants[0])
    (p / 'appendix.tex').unlink()
    assert 'companion source appendix.tex is missing' in build(p, 'main', ok=False)
    shutil.copyfile(repo / 'tests/fixtures/appendix.tex', p / 'appendix.tex')
    (p / 'appendix.tex').write_text('\\documentclass{article}\n\\begin{document}\\undefinedcommand\\end{document}\n')
    build(p, 'main', ok=False)
    (p / 'other.tex').write_text('\\documentclass{article}\n\\begin{document}Other\\end{document}\n')
    build(p, 'other')
    assert not (p / 'appendix.pdf').exists()
    print('PASS: Perl/TeX validation, missing sources, child failures, unrelated roots', flush=True)

    p = root / 'grammar'
    fixture(p, variants[1])
    original = (p / 'gdt-names.tex').read_text()
    (p / 'gdt-names.tex').write_text('% comment\n\t\n' + ''.join(
        '\t' + line + '\t % trailing comment\n' for line in original.splitlines()))
    build(p, names[0])
    resolved(p, names)
    print('PASS: whitespace/comment parser parity', flush=True)

    p = root / 'stale-aux'
    fixture(p, variants[0])
    (p / 'main.aux').write_text('\\relax\n\\newlabel{stale}{{99}{1}}\n')
    app = p / 'appendix.tex'
    app.write_text(app.read_text().replace('\\GDTMainDocument',
                   '\\GDTMainDocument\n\\makeatletter\n'
                   '\\@ifundefined{r@stale}{}{\\errmessage{Stale canonical auxiliary imported}}\n'
                   '\\makeatother'))
    build(p, 'main', ['-jobname=output'])
    resolved(p, variants[0], job='output')
    assert '{stale}' not in (p / 'main.aux').read_text()
    print('PASS: stale canonical auxiliary removal before companion compilation', flush=True)

    p = root / 'generic-helper'
    fixture(p, variants[1])
    source = p / f'{names[0]}.tex'
    source.write_text(source.read_text().replace('\\GDTAppendixDocument',
                      '\\GDTExternalDocument{\\GDTAppendixBase.tex}{\\GDTAppendixBase}'))
    build(p, names[0])
    resolved(p, names)
    print('PASS: generic two-argument helper compatibility', flush=True)

    p = root / 'wrappers'
    fixture(p, variants[1])
    (p / 'draft').mkdir()
    for i, helper in ((0, 'GDTAppendixDocument'), (1, 'GDTMainDocument')):
        source = p / f'{names[i]}.tex'
        body = source.read_text().replace('\\documentclass{article}\n', '')
        body = body.replace('\\input{body}', '\\input{draft/body}')
        body = f'% !TeX root = ../{names[i]}.tex\n' + body
        (p / 'draft' / f'{i}.tex').write_text(body)
        source.write_text('\\documentclass{article}\n\\usepackage{import}\n'
                         f'\\import{{draft/}}{{{i}.tex}}\n')
    (p / 'body.tex').rename(p / 'draft/body.tex')
    build(p, names[2])
    resolved(p, names, role=2)
    print('PASS: renamed nested entry wrappers', flush=True)

    # Verify the actual biblatex resource metadata without requiring Biber.
    # A full bibliography build is handled by the optional sample check below.
    (p / 'references').mkdir()
    (p / 'references/references.bib').write_text('@book{example, author={Author, A}, title={Example}, year={2026}}\n')
    for i in (0, 1):
        source = p / f'{names[i]}.tex'
        source.write_text(source.read_text().replace('\\usepackage{import}',
                         '\\usepackage{import}\n\\def\\GDTBibliographyBase{draft/}'))
        body = p / 'draft' / f'{i}.tex'
        body.write_text(body.read_text().replace('\\usepackage{gdt-build}',
                        '\\usepackage{biblatex}\n\\usepackage{gdt-build}\n'
                        '\\addbibresource{../references/references.bib}'))
        run(p, ['pdflatex', '-recorder', '-interaction=nonstopmode', '-halt-on-error', source.name])
        assert 'draft/../references/references.bib' in (p / f'{names[i]}.bcf').read_text()
    print('PASS: nested biblatex resource paths', flush=True)

    if shutil.which('biber'):
        p = root / 'full-sample'
        p.mkdir()
        tracked = run(repo, ['git', 'ls-files', '-z']).split('\0')
        for name in tracked:
            if not name or name in ('main.pdf', 'appendix.pdf', 'combined.pdf'):
                continue
            source = repo / name
            if source.is_file():
                target = p / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
        for name in ('gdt-names.tex', 'bibliography.sty'):
            shutil.copyfile(repo / name, p / name)
        build(p, 'combined')
        print('PASS: full sample including Biber', flush=True)
    else:
        print('SKIP: full sample bibliography build (Biber is not on PATH)', flush=True)
print('All build regressions passed.')
PY
