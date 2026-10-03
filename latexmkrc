# Build the other standalone document before each pass that needs its labels.
# The guard prevents recursion; latexmk itself handles Biber and reruns.
use File::Copy qw(copy);
use File::Spec;

$do_cd = 1;
$pdf_mode = 1;
$pdflatex = 'internal gdt_pdflatex %O %S';

sub gdt_sync_aux {
    my ($source) = @_;
    my ($role) = $source =~ m{(?:^|/)(main|appendix)\.tex$};
    return 0 unless $role;

    my $dir = (defined $aux_dir && length $aux_dir) ? $aux_dir : '.';
    my $job = (defined $jobname && length $jobname) ? $jobname : $role;
    my $actual = File::Spec->rel2abs(File::Spec->catfile($dir, "$job.aux"));
    my $canonical = File::Spec->rel2abs(File::Spec->catfile($dir, "$role.aux"));
    if (-e $actual) {
        return 0 if $actual eq $canonical;
        return copy($actual, $canonical) ? 0 : 1;
    }
    unlink $canonical if -e $canonical && $actual ne $canonical;
    return 0;
}

sub gdt_pdflatex {
    my @args = @_;
    my $source = $args[-1];
    my $companion;
    return 1 if gdt_sync_aux($source);

    unless ($ENV{GDT_XR_COMPANION}) {
        if ($source =~ m{(?:^|/)combined\.tex$}) {
            my @make = ('latexmk', '-pdf', '-cd', '-silent', '-interaction=nonstopmode', '-halt-on-error');
            push @make, "-outdir=$out_dir" if defined $out_dir && length $out_dir;
            push @make, 'main.tex';
            my $status = system @make;
            return $status if $status != 0;
        } elsif ($source =~ m{(?:^|/)main\.tex$}) {
            $companion = 'appendix';
        } elsif ($source =~ m{(?:^|/)appendix\.tex$}) {
            $companion = 'main';
        }
    }

    if ($companion) {
        local $ENV{GDT_XR_COMPANION} = 1;
        my @make = ('latexmk', '-pdf', '-cd', '-silent', '-interaction=nonstopmode', '-halt-on-error');
        push @make, "-outdir=$out_dir" if defined $out_dir && length $out_dir;
        push @make, "$companion.tex";
        my $status = system @make;
        return $status if $status != 0;
    }

    my $status = system 'pdflatex', '-shell-escape', @args;
    return $status if $status != 0;
    return gdt_sync_aux($source);
}
