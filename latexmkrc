# Build settings for every document in the project, the same on Overleaf and
# locally. Overleaf reads this file from the project root; latexmk reads the
# latexmkrc of the folder it starts in, so a folder of documents below the root
# has a latexmkrc of its own that loads this one:
#     do '../latexmkrc'; die "Cannot load ../latexmkrc: $@\n" if $@;
# Overleaf compiles with
#     latexmk -cd -jobname=output -auxdir=DIR -outdir=DIR -pdf FOLDER/MAIN.tex
# and, before each compile, deletes the generated files other than output.*,
# *.aux and *.pdf. Everything below works with and without these options.

use Cwd qw(abs_path getcwd);
use File::Basename qw(basename fileparse);
use File::Copy qw(copy);

# Compile in the source's folder, so that paths like ../figures/ resolve when
# latexmk is run from the project root; and with shell escape, for the svg
# package, which converts SVG figures with Inkscape.
$do_cd = 1;
set_tex_cmds('-shell-escape %O %S');

# The command line, which latexmk reads after this file.
my ($xr_job, $xr_dir, $xr_source) = ('', '.', '');
for (@ARGV) {
    if (/^--?jobname=(.+)$/) { $xr_job = $1 }
    elsif (/^--?(?:auxdir|aux-directory|outdir|output-directory)=(.+)$/) { $xr_dir = $1 }
    elsif (/\.tex$/) { $xr_source = $_ }
}

# A document whose first lines say "% !TeX program = xelatex" (or lualatex) is
# compiled with that engine when latexmk is asked for pdfLaTeX, as Overleaf and
# VimTeX ask by default: Overleaf's compiler then stays on pdfLaTeX for every
# document.
if ($xr_source ne '' && open my $fh, '<', $xr_source) {
    while (my $line = <$fh>) {
        last unless $line =~ /^\s*(?:%|$)/;
        next unless $line =~ /^\s*%\s*!\s*TeX\s+program\s*=\s*(xelatex|lualatex)\b/i;
        my $engine = '-' . lc $1;
        s/^-pdf$/$engine/ for @ARGV;
        last;
    }
    close $fh;
}

# Overleaf compiles every main document as "output". When the main document
# changes, the previous one's output.* files are removed first: latexmk would
# take its PDF for this document's, and TeX would read its .aux.
if ($xr_job ne '' && $xr_source ne '' && open my $fh, '<', "$xr_dir/$xr_job.fdb_latexmk") {
    my $recorded = '';
    while (<$fh>) {
        if (/^\["(?:pdf|xe|lua)?latex"\]\s+\S+\s+"([^"]*)"/) { $recorded = $1; last }
    }
    close $fh;
    if ($recorded ne '' && basename($recorded) ne basename($xr_source) && opendir my $dh, $xr_dir) {
        unlink map { "$xr_dir/$_" } grep { index($_, "$xr_job.") == 0 } readdir $dh;
        closedir $dh;
    }
}

# A document that attaches another one's PDF with \includepdf{NAME.pdf} (the
# combined document) gets NAME.pdf brought up to date before latexmk looks at it.
if ($xr_source ne '') {
    my ($name, $dir) = fileparse($xr_source, '.tex');
    pushd $dir;
    my (undef, $attached) = xr_scan("$name.tex");
    xr_build($_, $name, 'the PDF') for grep { -f "$_.tex" } @$attached;
    popd;
}

# Cross-document references (package xr). \externaldocument{NAME} reads
# NAME.aux beside the source. latexmk makes it, when it is missing or NAME.tex
# has changed, by compiling NAME.tex in its own folder. The manuscript and the
# appendix import each other's labels: a document that is being compiled is not
# compiled again by the other, which reads the labels it has saved so far.
push @file_not_found, '^No file\s*(.+)\s*$';
add_cus_dep('tex', 'aux', 0, 'xr_companion');

sub xr_companion {
    my ($name, $dir) = fileparse($_[0]);
    pushd $dir;
    xr_build($name, $tex_basename, 'the labels');
    popd;
    return 0;
}

$pdflatex = 'internal xr_pdflatex %O %S';

sub xr_pdflatex {
    # TeX looks for the other document's labels in the output folder before
    # this one, so a copy left there by an older setup would hide the current one.
    if ($aux_dir1 ne '' && abs_path($aux_dir) ne getcwd()) {
        my ($imports) = xr_scan($_[-1]);
        unlink "$aux_dir1$_.aux" for @$imports;
    }
    my $status = system 'pdflatex', '-shell-escape', @_;
    # Under another job name (Overleaf's "output"), the labels are also saved
    # as NAME.aux beside the source, where the other document reads them.
    copy("$aux_dir1$root_filename.aux", "$tex_basename.aux")
        if $root_filename ne $tex_basename && -e "$aux_dir1$root_filename.aux";
    return $status;
}

# Compile NAME.tex in the current folder with latexmk, for what document USER
# needs from it, unless NAME is being compiled already. A failure is reported
# but does not stop USER.
sub xr_build {
    my ($name, $user, $what) = @_;
    my @busy = split /:/, ($ENV{XR_BUSY} // '');
    return if grep { $_ eq $name } @busy, $user;
    local $ENV{XR_BUSY} = join ':', @busy, $user;
    print "xr: compiling $name.tex for $what that $user uses\n";
    system('latexmk', '-pdf', '-silent', '-interaction=nonstopmode', "$name.tex")
        and warn "xr: $name.tex failed to compile; see $name.log.\n";
}

# The documents a source file imports labels from (\externaldocument{NAME})
# and attaches as PDFs (\includepdf{NAME.pdf}).
sub xr_scan {
    my (@imports, @attached);
    open my $fh, '<', $_[0] or return ([], []);
    while (my $line = <$fh>) {
        $line =~ s/(?<!\\)%.*//;
        push @imports, $1 while $line =~ /\\externaldocument(?:\[[^\]]*\])*\{([^}]+)\}/g;
        push @attached, $1 while $line =~ /\\includepdf(?:\[[^\]]*\])?\{([^}]+)\.pdf\}/g;
    }
    return (\@imports, \@attached);
}

1;
