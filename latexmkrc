# Build the other standalone document before each pass that needs its labels.
# The guard prevents recursion; latexmk itself handles Biber and reruns.
use File::Copy qw(copy);
use File::Spec;
use File::Basename qw(dirname basename);
use Config;

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

sub gdt_sync_aux {
    my ($base) = @_;

    my $dir = (defined $aux_dir && length $aux_dir) ? $aux_dir : '.';
    my $job = (defined $jobname && length $jobname) ? $jobname : $base;
    my $actual = File::Spec->rel2abs(File::Spec->catfile($dir, "$job.aux"));
    my $canonical = File::Spec->rel2abs(File::Spec->catfile($dir, "$base.aux"));
    if (-e $actual) {
        return 0 if $actual eq $canonical;
        return copy($actual, $canonical) ? 0 : 1;
    }
    unlink $canonical if -e $canonical && $actual ne $canonical;
    return 0;
}

sub gdt_make {
    my ($base) = @_;
    unless (-f "$base.tex") {
        warn "GDT: configured companion source $base.tex is missing; check gdt-names.tex.\n";
        return 1;
    }
    my @make = ('latexmk', '-pdf', '-cd', '-silent', '-interaction=nonstopmode', '-halt-on-error');
    push @make, "-outdir=$out_dir" if defined $out_dir && length $out_dir;
    push @make, "-auxdir=$aux_dir" if defined $aux_dir && length $aux_dir;
    push @make, '-emulate-aux-dir' if $emulate_aux;
    # Explicitly override server/user jobname settings for companion outputs.
    push @make, "-jobname=$base", "$base.tex";
    return system @make;
}

sub gdt_pdflatex {
    my @args = @_;
    my $source = $args[-1];
    my %names = gdt_names(); # Also refresh during a continuous (-pvc) session.
    my $base = basename($source);
    $base =~ s/\.tex$//;
    my ($role) = grep { $names{$_} eq $base } keys %names;
    my $companion;
    my $standalone = defined $role && $role ne 'Combined';
    return 1 if $standalone && gdt_sync_aux($base);

    unless ($ENV{GDT_XR_COMPANION}) {
        if (defined $role && $role eq 'Combined') {
            my $status = gdt_make($names{Main});
            return $status if $status != 0;
        } elsif (defined $role && $role eq 'Main') {
            $companion = $names{Appendix};
        } elsif (defined $role && $role eq 'Appendix') {
            $companion = $names{Main};
        }
    }

    if ($companion) {
        local $ENV{GDT_XR_COMPANION} = 1;
        my $status = gdt_make($companion);
        return $status if $status != 0;
    }

    # With emulated separate aux directories, latexmk adds the aux directory
    # to TeX's search path, but pdfpages also needs the final output directory.
    local $ENV{TEXINPUTS} = (defined $out_dir && length $out_dir)
        ? File::Spec->rel2abs($out_dir) . $Config{path_sep} . ($ENV{TEXINPUTS} // '')
        : ($ENV{TEXINPUTS} // '');
    my $status = system 'pdflatex', '-shell-escape', @args;
    return $status if $status != 0;
    return $standalone ? gdt_sync_aux($base) : 0;
}
