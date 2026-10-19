#!/usr/bin/env bash
# Real builds in disposable projects; no repository PDFs or auxiliaries copied.
set -euo pipefail
repo="$(dirname "$(dirname "$(realpath "$0")")")"
exec python3 - "$repo" <<'PY'
import fcntl
import hashlib
import os
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


def wrap(project, names):
    # Move both standalone bodies to draft/ behind thin root entry wrappers.
    (project / 'draft').mkdir()
    for i in (0, 1):
        source = project / f'{names[i]}.tex'
        body = source.read_text().replace('\\documentclass{article}\n', '')
        body = body.replace('\\input{body}', '\\input{draft/body}')
        body = f'% !TeX root = ../{names[i]}.tex\n' + body
        (project / 'draft' / f'{i}.tex').write_text(body)
        source.write_text('\\documentclass{article}\n\\usepackage{import}\n'
                          f'\\import{{draft/}}{{{i}.tex}}\n')
    (project / 'body.tex').rename(project / 'draft/body.tex')


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
    # Builds keep their lock files in the system's temporary directory.
    os.environ['TMPDIR'] = tmp
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
    out = build(p, 'main')
    assert 'GDT: appendix failed to build, so references to it may be missing' in out, out
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
    wrap(p, names)
    build(p, names[2])
    resolved(p, names, role=2)
    print('PASS: renamed nested entry wrappers', flush=True)

    # Only the companion's own sources make it stale; this document's labels do not.
    q = root / 'incremental'
    fixture(q, variants[0])
    build(q, 'main')
    stamp = (q / 'appendix.pdf').stat().st_mtime_ns
    (q / 'body.tex').write_text('\\setcounter{section}{4}\n'
                                + (repo / 'tests/fixtures/body.tex').read_text())
    out = build(q, 'main')
    assert 'GDT: building' not in out, out
    assert (q / 'appendix.pdf').stat().st_mtime_ns == stamp
    assert '\\newlabel{main:result}{{5}' in (q / 'main.aux').read_text()
    build(q, 'appendix')
    assert 'Manuscript reference: 5.' in text(q, 'appendix.pdf')
    app = q / 'appendix.tex'
    app.write_text(app.read_text().replace('{6}', '{8}'))
    out = build(q, 'main')
    assert 'GDT: building appendix because appendix.tex changed' in out, out
    assert 'Appendix reference: 9.' in text(q, 'main.pdf')
    run(q, ['latexmk', '-c', 'main.tex'])
    assert not (q / 'main.gdt.aux').exists()
    print('PASS: companion rebuilt only when its own sources change', flush=True)

    q = root / 'wrapper-edits'
    fixture(q, names)
    wrap(q, names)
    build(q, names[0])
    body = q / 'draft/1.tex'
    body.write_text(body.read_text().replace('{6}', '{8}'))
    out = build(q, names[0])
    assert f'GDT: building {names[1]} because 1.tex changed' in out, out
    assert 'Appendix reference: 9.' in text(q, f'{names[0]}.pdf')
    print('PASS: nested companion sources', flush=True)

    # Overleaf runs this command (services/clsi/app/js/LatexRunner.js) and, before
    # each compile, deletes generated files except output.*, *.aux and *.pdf, and
    # its own final outputs (ResourceWriter.isExtraneousFile).
    def overleaf(project, name):
        out = run(project, ['latexmk', '-cd', '-jobname=output', f'-auxdir={project}',
                            f'-outdir={project}', '-synctex=1', '-interaction=batchmode',
                            '-time', '-f', '-pdf', str(project / f'{name}.tex')])
        pdf = text(project, 'output.pdf')
        for item in project.iterdir():
            rel = item.name
            if item.is_dir() or rel in sources:
                continue
            keep = rel.startswith('output.') or rel.endswith(('.aux', '.pdf'))
            if not keep or rel in ('output.pdf', 'output.log', 'output.synctex.gz'):
                item.unlink()
        return out, pdf

    q = root / 'overleaf'
    fixture(q, variants[0])
    sources = {item.name for item in q.iterdir()}
    out, pdf = overleaf(q, 'main')
    assert 'Appendix reference: 7.' in pdf, pdf
    assert 'Manuscript reference: 1.' in text(q, 'appendix.pdf')
    out, pdf = overleaf(q, 'main')
    assert 'GDT: building' not in out and 'Appendix reference: 7.' in pdf, out
    (q / 'body.tex').write_text('\\setcounter{section}{4}\n'
                                + (repo / 'tests/fixtures/body.tex').read_text())
    out, pdf = overleaf(q, 'main')
    assert 'GDT: building' not in out and 'Appendix reference: 7.' in pdf, out
    app = q / 'appendix.tex'
    app.write_text(app.read_text().replace('{6}', '{8}'))
    out, pdf = overleaf(q, 'main')
    assert 'GDT: building appendix because appendix.tex changed' in out, out
    assert 'Appendix reference: 9.' in pdf, pdf
    out, pdf = overleaf(q, 'appendix')
    assert 'Manuscript reference: 5.' in pdf, pdf
    out, pdf = overleaf(q, 'combined')
    assert pdf.index('MANUSCRIPT-FIRST') < pdf.index('APPENDIX-SECOND'), pdf
    assert 'Appendix reference: 9.' in pdf and 'Manuscript reference: 5.' in pdf, pdf
    print('PASS: Overleaf compiles keep companion state between compiles', flush=True)

    # A running compiler owns its document: others use its labels, never build it.
    q = root / 'concurrent'
    fixture(q, variants[0])
    build(q, 'main')
    app = q / 'appendix.tex'
    app.write_text(app.read_text().replace('{6}', '{8}'))
    log = (q / 'continuous.txt').open('w')
    proc = subprocess.Popen(['latexmk', '-pdf', '-pvc', '-view=none', '-silent',
                             '-interaction=nonstopmode', '-halt-on-error', 'appendix.tex'],
                            cwd=q, stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 45
        while '\\newlabel{app:result}{{9}' not in (q / 'appendix.aux').read_text():
            assert time.monotonic() < deadline and proc.poll() is None, \
                (q / 'continuous.txt').read_text()
            time.sleep(0.3)
        app.write_text(app.read_text().replace('{8}', '{10}'))
        out = build(q, 'main')
        assert 'appendix is being compiled by another process' in out, out
        assert 'GDT: building appendix' not in out, out
        out = build(q, 'appendix', ok=False)
        assert 'appendix is already being compiled' in out, out
    finally:
        proc.terminate()
        proc.wait(timeout=15)
        log.close()
    print('PASS: concurrent compilers of the same draft', flush=True)

    # An error in the companion does not stop this document, and the companion
    # is built again once its source is fixed.
    q = root / 'failed-companion'
    fixture(q, variants[0])
    build(q, 'main')
    app = q / 'appendix.tex'
    good = app.read_text()
    app.write_text(good.replace('\\begin{document}', '\\begin{document}\\undefinedcommand'))
    stamp = (q / 'main.pdf').stat().st_mtime_ns
    out = build(q, 'main')
    assert 'GDT: appendix failed to build' in out, out
    assert (q / 'main.pdf').stat().st_mtime_ns != stamp
    build(q, 'main')
    app.write_text(good.replace('{6}', '{8}'))
    out = build(q, 'main')
    assert 'GDT: building appendix because appendix.tex changed' in out, out
    assert 'Appendix reference: 9.' in text(q, 'main.pdf')
    print('PASS: a failed companion does not stop this document', flush=True)

    # A pass stopped mid-write leaves files cut off, and latexmk records the
    # pass as failed. Starting the compiler again must repair and rebuild.
    q = root / 'interrupted'
    fixture(q, variants[0])
    build(q, 'main')
    for name in ('main.aux', 'main.pdf', 'appendix.aux'):
        data = (q / name).read_bytes()
        (q / name).write_bytes(data[:len(data) // 2].rstrip(b'\n') + b'{')
    for name in ('main.fdb_latexmk', 'appendix.fdb_latexmk'):
        fdb = q / name
        fdb.write_text(re.sub(r'^(\["pdflatex"\] .*) 0$', r'\1 2', fdb.read_text(), flags=re.M))
    out = build(q, 'main')
    for name in ('main.aux', 'main.pdf', 'appendix.aux'):
        assert f'GDT: removed {name}, which an interrupted pass left incomplete.' in out, out
    resolved(q, variants[0])
    print('PASS: files cut off by a stopped compiler are rebuilt', flush=True)

    # A pass reads the other document's files only while no pass of it runs.
    q = root / 'pass-lock'
    fixture(q, variants[0])
    build(q, 'appendix')
    app = q / 'appendix.tex'
    app.write_text(app.read_text().replace('{6}', '{8}'))
    key = hashlib.md5(str((q / 'main.aux').resolve()).encode()).hexdigest()
    with (root / f'gdt-{key}.pass.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        proc = subprocess.Popen(['latexmk', '-pdf', '-silent', '-interaction=nonstopmode',
                                 '-halt-on-error', 'appendix.tex'], cwd=q, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        time.sleep(3)
        assert proc.poll() is None, proc.communicate()[0]
        fcntl.flock(lock, fcntl.LOCK_UN)
    out = proc.communicate(timeout=60)[0]
    assert proc.returncode == 0, out
    assert 'GDT: waiting for the current pass of main to finish.' in out, out
    assert 'Manuscript reference: 1.' in text(q, 'appendix.pdf')
    print('PASS: passes wait for the other document to finish writing', flush=True)

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
