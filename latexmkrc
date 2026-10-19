# Build the other standalone document (the companion) only when the labels
# imported from it can be stale: its auxiliary file is missing, its own sources
# changed since this job last built it, or it was built before this document
# had labels. This document's labels never trigger a companion rebuild, so an
# edit costs one document's passes. The combined target rebuilds both until
# their labels agree. latexmk itself handles Biber and reruns. A companion that
# fails to build does not stop this document.
use File::Copy qw(copy);
use File::Spec;
use File::Basename qw(dirname basename);
use Config;
use Cwd ();
use Digest::MD5;
use Fcntl qw(:flock);
use IO::Handle;

# Capture the rc location before latexmk's -cd changes the working directory.
my $gdt_config = File::Spec->rel2abs('gdt-names.tex', dirname(__FILE__));

sub gdt_names {
    open my $fh, '<', $gdt_config or die "GDT: cannot read $gdt_config: $!\n";
    my (%names, %seen);
    while (my $line = <$fh>) {
        $line =~ s/%.*//;
        next if $line =~ /^\s*$/;
        $line =~ /^\s*\\def\\GDT(Main|Appendix|Combined)Base\{([A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9_-])?)\}\s*$/
            or die "GDT: invalid gdt-names.tex line $.; use literal \\def\\GDTRoleBase{basename} (no paths or trailing dots).\n";
        my ($role, $name) = ($1, $2);
        die "GDT: duplicate definition for GDT${role}Base.\n" if exists $names{$role};
        die "GDT: basenames must be distinct (case-insensitive): $name.\n" if $seen{lc $name}++;
        $names{$role} = $name;
    }
    close $fh;
    for my $role (qw(Main Appendix Combined)) {
        die "GDT: missing \\def\\GDT${role}Base{basename} in gdt-names.tex.\n" unless exists $names{$role};
    }
    return %names;
}
gdt_names();

$do_cd = 1;
$pdf_mode = 1;
$pdflatex = 'internal gdt_pdflatex %O %S';
# The companion state is named *.aux so that Overleaf keeps it between compiles.
$clean_ext = join ' ', grep { length } ($clean_ext // ''), 'gdt.aux';

sub gdt_file {
    my ($dir, $base, $ext) = @_;
    $dir = '.' unless defined $dir && length $dir;
    return File::Spec->canonpath(File::Spec->rel2abs(File::Spec->catfile($dir, "$base.$ext")));
}

sub gdt_sync_aux {
    my ($base) = @_;

    my $job = (defined $jobname && length $jobname) ? $jobname : $base;
    my $actual = gdt_file($aux_dir, $job, 'aux');
    my $canonical = gdt_file($aux_dir, $base, 'aux');
    if (-e $actual) {
        return 0 if $actual eq $canonical;
        return copy($actual, $canonical) ? 0 : 1;
    }
    unlink $canonical if -e $canonical && $actual ne $canonical;
    return 0;
}

sub gdt_make {
    my ($base) = @_;
    # The child imports labels but builds no companion of its own.
    local $ENV{GDT_XR_COMPANION} = 1;
    my @make = ('latexmk', '-pdf', '-cd', '-silent', '-interaction=nonstopmode', '-halt-on-error');
    push @make, "-outdir=$out_dir" if defined $out_dir && length $out_dir;
    push @make, "-auxdir=$aux_dir" if defined $aux_dir && length $aux_dir;
    push @make, '-emulate-aux-dir' if $emulate_aux;
    # Explicitly override server/user jobname settings for companion outputs.
    push @make, "-jobname=$base", "$base.tex";
    return system @make;
}

# Inputs of a standalone document --------------------------------------------

# Canonical auxiliary files of the other standalone roles, which $base imports.
sub gdt_partner_auxes {
    my ($base, %names) = @_;
    return map { gdt_file($aux_dir, $names{$_}, 'aux') }
        grep { $names{$_} ne $base } qw(Main Appendix);
}

# Files that $base read in its last pass, from its recorder file. Generated
# files are left out, except the partner auxiliary files it imports. So are
# the partner entry sources: xr opens them only to resolve their names.
sub gdt_inputs {
    my ($base, %names) = @_;
    open my $fh, '<', gdt_file($aux_dir, $base, 'fls') or return;
    my ($pwd, @read, @written);
    while (my $line = <$fh>) {
        $line =~ s/\r?\n\z//;
        if ($line =~ /^PWD (.*)/) { $pwd = $1 }
        elsif ($line =~ /^INPUT (.*)/) { push @read, $1 }
        elsif ($line =~ /^OUTPUT (.*)/) { push @written, $1 }
    }
    close $fh;
    my $abs = sub { File::Spec->canonpath(File::Spec->rel2abs($_[0], $pwd)) };
    my %written = map { $abs->($_) => 1 } @written;
    my %partner = map { $_ => 1 } gdt_partner_auxes($base, %names);
    my %skip = map { gdt_file('.', $names{$_}, 'tex') => 1 }
        grep { $names{$_} ne $base } qw(Main Appendix);
    my (%seen, @files);
    for my $path (map { $abs->($_) } @read) {
        next if $seen{$path}++ || $written{$path} || $skip{$path};
        next if $path =~ /\.(?:aux|bbl|bcf|blg|out|toc|lof|lot|fls|log|run\.xml|synctex(?:\.gz)?|nav|snm|vrb)\z/i
            && !$partner{$path};
        push @files, $path;
    }
    return @files;
}

sub gdt_md5 {
    open my $fh, '<:raw', $_[0] or return '';
    return Digest::MD5->new->addfile($fh)->hexdigest;
}

# latexmk loads Time::HiRes, so modification times can have a fraction.
sub gdt_same_time { abs($_[0] - $_[1]) < 1e-3 }

# Companion state: for each document this job built, its inputs as they were,
# and which partner auxiliary files had no labels yet (latexmk writes a dummy
# .aux before a first pass).

sub gdt_has_labels {
    open my $fh, '<', $_[0] or return 0;
    while (my $line = <$fh>) { return 1 if index($line, '\newlabel{') >= 0 }
    return 0;
}

sub gdt_read_state {
    my ($file) = @_;
    my (%state, $doc);
    open my $fh, '<', $file or return \%state;
    my $header = <$fh> // '';
    return \%state unless $header =~ /^% GDT companion state 1\s*$/;
    while (my $line = <$fh>) {
        $line =~ s/\r?\n\z//;
        if ($line =~ /^document (\S+)$/) { $state{$doc = $1} = {items => [], unlabelled => {}} }
        elsif (!defined $doc) { next }
        elsif ($line =~ /^input (\d+) ([\d.]+) ([0-9a-f]{32}) (.+)$/) {
            push @{$state{$doc}{items}}, [$1, $2, $3, $4];
        }
        elsif ($line =~ /^unlabelled (.+)$/) { $state{$doc}{unlabelled}{$1} = 1 }
    }
    return \%state;
}

sub gdt_write_state {
    my ($file, $state) = @_;
    open my $fh, '>', "$file.tmp" or do { warn "GDT: cannot write $file: $!\n"; return };
    print $fh "% GDT companion state 1\n";
    for my $doc (sort keys %$state) {
        print $fh "document $doc\n";
        print $fh "input $_->[0] $_->[1] $_->[2] $_->[3]\n" for @{$state->{$doc}{items}};
        print $fh "unlabelled $_\n" for sort keys %{$state->{$doc}{unlabelled}};
    }
    close $fh;
    rename "$file.tmp", $file or warn "GDT: cannot write $file: $!\n";
}

sub gdt_record {
    my ($state, $doc, %names) = @_;
    my %old = map { $_->[3] => $_ } @{$state->{$doc}{items} // []};
    my @inputs = gdt_inputs($doc, %names);
    # Without a recorder file, assume the entry source and imported labels.
    @inputs = (gdt_file('.', $doc, 'tex'), grep { -e } gdt_partner_auxes($doc, %names))
        unless @inputs;
    my (@items, %read);
    for my $path (@inputs) {
        my @st = stat $path or next;
        my $old = $old{$path};
        my $md5 = ($old && $old->[0] == $st[7] && gdt_same_time($old->[1], $st[9]))
            ? $old->[2] : gdt_md5($path);
        push @items, [$st[7], sprintf('%.6f', $st[9]), $md5, $path];
        $read{$path} = 1;
    }
    my %unlabelled = map { $_ => 1 }
        grep { $read{$_} && !gdt_has_labels($_) } gdt_partner_auxes($doc, %names);
    $state->{$doc} = {items => \@items, unlabelled => \%unlabelled};
}

# Why $doc must be rebuilt, or '' when its last build is current. Inputs in
# %$ignore may change without a rebuild, except that a partner auxiliary file
# counts once it has labels that the last build of $doc could not import.
sub gdt_stale {
    my ($state, $doc, $ignore, $need_pdf, %names) = @_;
    my $entry = $state->{$doc} or return 'it was not built by this job yet';
    return 'its auxiliary file is missing' unless -e gdt_file($aux_dir, $doc, 'aux');
    return 'its PDF is missing' if $need_pdf && !-e gdt_file($out_dir, $doc, 'pdf');
    my %recorded = map { $_->[3] => 1 } @{$entry->{items}};
    for my $partner (gdt_partner_auxes($doc, %names)) {
        next unless -e $partner && ($entry->{unlabelled}{$partner} || !$recorded{$partner});
        return basename($partner) . ' has labels now' if gdt_has_labels($partner);
    }
    for my $item (@{$entry->{items}}) {
        my ($size, $mtime, $md5, $path) = @$item;
        next if $ignore->{$path};
        my @st = stat $path or return basename($path) . ' was removed';
        next if $st[7] == $size && gdt_same_time($st[9], $mtime);
        return basename($path) . ' changed' if $st[7] != $size || gdt_md5($path) ne $md5;
    }
    return '';
}

# Interrupted passes -----------------------------------------------------------

# A pass stopped by a signal (a compiler stopped from the editor, say) leaves
# its files cut off mid-write. TeX then stops on them in every later pass, and
# latexmk, which recorded the stopped pass as failed, sees nothing to do. TeX
# writes whole lines, Biber's control file ends with its closing tag and a PDF
# with %%EOF, so a file that does not is removed and written again.
sub gdt_incomplete {
    my ($path) = @_;
    my $size = -s $path or return 0;
    open my $fh, '<:raw', $path or return 0;
    my $n = $size < 1024 ? $size : 1024;
    seek $fh, -$n, 2;
    read $fh, my $tail, $n;
    close $fh;
    return $tail !~ m{</bcf:controlfile>\s*\z} if $path =~ /\.bcf\z/i;
    return $tail !~ /%%EOF\s*\z/ if $path =~ /\.pdf\z/i;
    return $tail !~ /\n\z/;
}

# Only for a document that no other process is compiling.
sub gdt_repair {
    my ($job, $aux, $out) = @_;
    ($aux, $out) = ($aux_dir, $out_dir) if @_ == 1;
    my @files = ((map { gdt_file($aux, $job, $_) } qw(aux bcf toc lof lot out)),
        gdt_file($out, $job, 'pdf'));
    for my $file (grep { gdt_incomplete($_) } @files) {
        print 'GDT: removed ', basename($file), ", which an interrupted pass left incomplete.\n"
            if unlink $file;
    }
}

# Build locks: one compiler per document and auxiliary directory ---------------

my %gdt_locks;

sub gdt_lock_path {
    my ($aux_file, $kind) = @_;
    my $key = Digest::MD5::md5_hex($aux_file);
    return File::Spec->catfile(File::Spec->tmpdir, "gdt-$key$kind.lock");
}

sub gdt_lock_handle {
    my ($base) = @_;
    open my $fh, '+>>', gdt_lock_path(gdt_file($aux_dir, $base, 'aux'), '') or return;
    return $fh;
}

sub gdt_claim {
    my ($base, $fh, $mode) = @_;
    truncate $fh, 0;
    print $fh "$mode $$\n";
    $fh->flush;
    $gdt_locks{$base} = $fh;
}

# Hold the selected root's lock until this latexmk exits. Wait for a companion
# build of the same document; refuse to run beside another compiler of it.
sub gdt_lock_root {
    my ($base) = @_;
    return 0 if $gdt_locks{$base};
    my $fh = gdt_lock_handle($base) or return 0;
    my $tries = 20;
    until (flock $fh, LOCK_EX | LOCK_NB) {
        seek $fh, 0, 0;
        my $holder = <$fh> // '';
        if ($holder =~ /^root (\d+)/) {
            if (--$tries > 0) { select undef, undef, undef, 0.5; next }
            warn "GDT: $base is already being compiled in this output directory (process $1). "
                . "Stop that compiler or build into another directory.\n";
            return 1;
        }
        print "GDT: waiting for another build of $base to finish.\n";
        flock $fh, LOCK_EX or return 0;
        last;
    }
    gdt_claim($base, $fh, 'root');
    return 0;
}

# Pass locks: TeX empties a document's auxiliary file when a pass starts and
# fills it as the pass runs, so another compiler must not read it meanwhile. A
# pass holds its own document's lock exclusively and those of the documents it
# reads shared, all taken in one order, so compilers cannot deadlock.
sub gdt_pass_locks {
    my (%mode) = @_;
    my %path = map { $_ => gdt_lock_path(gdt_file($aux_dir, $_, 'aux'), '.pass') } keys %mode;
    my @held;
    for my $doc (sort { $path{$a} cmp $path{$b} } keys %mode) {
        open my $fh, '>>', $path{$doc} or next;
        unless (flock $fh, $mode{$doc} | LOCK_NB) {
            print "GDT: waiting for the current pass of $doc to finish.\n";
            flock $fh, $mode{$doc} or next;
        }
        push @held, $fh;
    }
    return @held;
}

# Rebuild $doc for this job if gdt_stale says so. Returns (status, built). A
# failed build is reported but does not stop this document, so that an error in
# one document cannot block the other.
sub gdt_refresh {
    my ($job, $doc, $ignore, $need_pdf, %names) = @_;
    unless (-f "$doc.tex") {
        warn "GDT: configured companion source $doc.tex is missing; check gdt-names.tex.\n";
        return (1, 0);
    }
    my $fh = gdt_lock_handle($doc);
    my $free = !$fh || flock $fh, LOCK_EX | LOCK_NB;
    gdt_repair($doc) if $free;
    my $file = gdt_file($aux_dir, $job, 'gdt.aux');
    my $state = gdt_read_state($file);
    my $reason = gdt_stale($state, $doc, $ignore, $need_pdf, %names) or return (0, 0);
    unless ($free) {
        print "GDT: $doc is being compiled by another process; using its current labels.\n";
        return (0, 0);
    }
    gdt_claim($doc, $fh, 'companion') if $fh;
    print "GDT: building $doc because $reason.\n";
    my $status = gdt_make($doc);
    close delete $gdt_locks{$doc} if $fh;
    if ($status != 0) {
        warn "GDT: $doc failed to build, so references to it may be missing. See ",
            basename(gdt_file($aux_dir, $doc, 'log')), " for the error.\n";
        return (0, 0);
    }
    gdt_record($state, $doc, %names);
    gdt_write_state($file, $state);
    return (0, 1);
}

# Documents whose sources the current pass should also depend on.
my @gdt_tracked;

sub gdt_pdflatex {
    my @args = @_;
    my $source = $args[-1];
    my %names = gdt_names(); # Also refresh during a continuous (-pvc) session.
    my $base = basename($source);
    $base =~ s/\.tex$//;
    my ($role) = grep { $names{$_} eq $base } keys %names;
    my $standalone = defined $role && $role ne 'Combined';
    my $job = (defined $jobname && length $jobname) ? $jobname : $base;
    my $child = $ENV{GDT_XR_COMPANION};
    @gdt_tracked = !defined $role ? ()
        : $standalone ? ($names{$role eq 'Main' ? 'Appendix' : 'Main'})
        : ($names{Main}, $names{Appendix});

    if (defined $role && !$child) {
        my $status = gdt_lock_root($base);
        return $status if $status;
        # A companion build's files were repaired by the job that started it.
        gdt_repair($_) for grep { length } $job, ($job ne $base ? $base : '');
    }
    return 1 if $standalone && gdt_sync_aux($base);

    if ($standalone && !$child) {
        # This document's own labels are no reason to rebuild the companion.
        my ($status) = gdt_refresh($job, $gdt_tracked[0],
            {gdt_file($aux_dir, $base, 'aux') => 1}, 0, %names);
        return $status if $status != 0;
    } elsif (defined $role && !$standalone && !$child) {
        my $settled;
        for my $round (1 .. 4) {
            my $built = 0;
            for my $doc (@gdt_tracked) {
                my ($status, $did) = gdt_refresh($job, $doc, {}, 1, %names);
                return $status if $status != 0;
                $built ||= $did;
            }
            unless ($built) { $settled = 1; last }
        }
        warn "GDT: labels of $names{Main} and $names{Appendix} did not settle in four rounds.\n"
            unless $settled;
    }

    # With emulated separate aux directories, latexmk adds the aux directory
    # to TeX's search path, but pdfpages also needs the final output directory.
    local $ENV{TEXINPUTS} = (defined $out_dir && length $out_dir)
        ? File::Spec->rel2abs($out_dir) . $Config{path_sep} . ($ENV{TEXINPUTS} // '')
        : ($ENV{TEXINPUTS} // '');
    my @pass;
    if (defined $role) {
        @pass = gdt_pass_locks($base => LOCK_EX, map { $_ => LOCK_SH } @gdt_tracked);
        # With no pass of them running, an incomplete file is a leftover.
        gdt_repair($_) for @gdt_tracked;
    }
    my $status = system 'pdflatex', '-shell-escape', @args;
    return $status if $status != 0;
    return $standalone ? gdt_sync_aux($base) : 0;
}

# After latexmk's own dependency analysis of a pass, make the pass depend on
# the companions' sources too, so that latexmk (and -pvc) reruns it when the
# other document changes. They are added here rather than read by TeX, which
# keeps them out of this document's recorder file. Needs latexmk 4.84 or later;
# older versions still refresh the companion on every pass of this document.
sub gdt_track_companions {
    my %names = gdt_names();
    for my $doc (@gdt_tracked) {
        rdb_ensure_file($rule, "$doc.tex");
        rdb_ensure_file($rule, $_) for grep { !/\.aux\z/i } gdt_inputs($doc, %names);
    }
    return 0;
}
add_hook('after_xlatex_analysis', \&gdt_track_companions) if defined &add_hook;

# Repair the selected document before latexmk examines it, or a compile that
# was stopped mid-pass finds nothing to do when it is started again. latexmk
# reads this file before its command line, so read the options that place the
# document's files here.
sub gdt_repair_selected {
    return if $ENV{GDT_XR_COMPANION};
    my (%opt, @files);
    my @args = @ARGV;
    while (defined(my $arg = shift @args)) {
        if ($arg =~ /^--?[er]\z/) { shift @args; next }
        if ($arg =~ /^--?(outdir|output-directory|auxdir|aux-directory|jobname)=(.+)\z/) {
            $opt{$1} = $2;
            next;
        }
        push @files, $arg unless $arg =~ /^-/;
    }
    return unless @files == 1;
    my %names = gdt_names();
    my $base = basename($files[0]);
    $base =~ s/\.tex\z//;
    return unless grep { $_ eq $base } values %names;
    my $dir = Cwd::abs_path(dirname(File::Spec->rel2abs($files[0]))) // return;
    my $out = $opt{outdir} // $opt{'output-directory'} // $out_dir // '';
    my $aux = $opt{auxdir} // $opt{'aux-directory'} // $aux_dir // '';
    $aux = $out unless length $aux;
    my ($at_out, $at_aux) = map { File::Spec->rel2abs(length $_ ? $_ : '.', $dir) } $out, $aux;
    my $job = $opt{jobname} // ((defined $jobname && length $jobname) ? $jobname : $base);
    open my $fh, '+>>', gdt_lock_path(gdt_file($at_aux, $base, 'aux'), '') or return;
    flock $fh, LOCK_EX | LOCK_NB or return; # another compiler owns the document
    gdt_repair($_, $at_aux, $at_out) for grep { length } $job, ($job ne $base ? $base : '');
    close $fh;
}
gdt_repair_selected();
