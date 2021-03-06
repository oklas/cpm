#!/usr/bin/env perl
BEGIN { $ENV{PERL_JSON_BACKEND} = 0 } # force JSON::PP, https://github.com/perl-carton/carton/issues/214
use 5.24.0;
use FindBin;
use lib "$FindBin::Bin/../lib";
use App::FatPacker::Simple;
use App::cpm;
use Config;
use File::Path 'remove_tree';
use Carton::Snapshot;
use CPAN::Meta::Requirements;
use Getopt::Long ();
use Path::Tiny ();
chdir $FindBin::Bin;

=for hint

Show new dependencies

    git diff cpm | perl -nle 'print $1 if /^\+\$fatpacked\{"([^"]+)/'

=cut

Getopt::Long::GetOptions "f|force" => \my $force, "t|test" => \my $test;

sub cpm {
    App::cpm->new->run(@_) == 0 or die
}

sub fatpack {
    App::FatPacker::Simple->new->parse_options(@_)->run
}

sub remove_version_xs {
    my $arch = $Config{archname};
    my $file = "local/lib/perl5/$arch/version/vxs.pm";
    my $dir  = "local/lib/perl5/$arch/auto/version";
    unlink $file if -f $file;
    remove_tree $dir if -d $dir;
}

sub gen_snapshot {
    my $snapshot = Carton::Snapshot->new(path => "cpanfile.snapshot");
    my $no_exclude = CPAN::Meta::Requirements->new;
    $snapshot->find_installs("local", $no_exclude);
    $snapshot->save;
}

sub git_info {
    my $describe = `git describe --tags --dirty`;
    chomp $describe;
    my $hash = `git rev-parse --short HEAD`;
    chomp $hash;
    my $url = "https://github.com/skaji/cpm/tree/$hash";
    ($describe, $url);
}

sub inject_git_info {
    my ($file, $describe, $url) = @_;
    my $inject = <<~"___";
    \$App::cpm::GIT_DESCRIBE = '$describe';
    \$App::cpm::GIT_URL = '$url';
    ___
    my $content = Path::Tiny->new($file)->slurp_raw;
    $content =~ s/^use App::cpm;/use App::cpm;\n$inject/sm;
    Path::Tiny->new($file)->spew_raw($content);
}


my $exclude = join ",", qw(
    Carp
    Digest::SHA
    ExtUtils::CBuilder
    ExtUtils::MakeMaker
    ExtUtils::MakeMaker::CPANfile
    ExtUtils::ParseXS
    File::Spec
    Module::Build::Tiny
    Module::CoreList
    Params::Check
    Perl::OSType
    Test
    Test2
    Test::Harness
);
my @extra = qw(
    Class::C3
    Devel::GlobalDestruction
    MRO::Compat
);

my $target = '5.8.1';

my ($git_describe, $git_url) = git_info;
warn "\e[1;31m!!! GIT IS DIRTY !!!\e[m\n" if $git_describe =~ /dirty/;

my @copyright = Path::Tiny->new("copyrights-and-licenses.json")->lines({chomp => 1});
my $copyright = join "\n", map { "# $_" } @copyright;

my $shebang = <<"___";
#!/usr/bin/env perl
use $target;

# The following distributions are embedded into this script:
#
$copyright
___

my $resolver = -f "cpanfile.snapshot" && !$force && !$test ? "snapshot" : "metacpan";

warn "Resolver: $resolver\n";
cpm "install", "--cpanfile", "../cpanfile", "--target-perl", $target, "--resolver", $resolver;
cpm "install", "--cpanfile", "../cpanfile", "--target-perl", $target, "--resolver", $resolver, @extra;
gen_snapshot if !$test;
remove_version_xs;
print STDERR "FatPacking...";

my $fatpack_dir = $test ? "local" : "../lib,local";
my $output = $test ? "../cpm.test" : "../cpm";
fatpack "-q", "-o", $output, "-d", $fatpack_dir, "-e", $exclude, "--shebang", $shebang, "../script/cpm";
print STDERR " DONE\n";
inject_git_info($output, $git_describe, $git_url);
