use Test;

my $root = $?FILE.IO.parent.parent.absolute.IO;
my $checkout = $*TMPDIR.add("red-mysql-revision-test-{$*PID}-{1000000.rand.Int}");
$checkout.mkdir;
sub remove-tree(IO::Path $path) {
    if $path.d && !$path.l {
        remove-tree($_) for $path.dir;
        $path.rmdir;
    } else {
        $path.unlink;
    }
}
LEAVE { remove-tree($checkout) }
sub git(*@args) {
    my $process = run 'git', '-C', $checkout.Str, |@args, :out, :err;
    my $out = $process.out.slurp-rest;
    my $err = $process.err.slurp-rest;
    die "git failed: $err" if $process.exitcode;
    $out.trim
}
git('init', '--quiet');
git('-c', 'user.name=Runner Test', '-c', 'user.email=runner@example.invalid',
    '-c', 'commit.gpgsign=false', 'commit', '--quiet', '--allow-empty', '-m', 'different revision');
my $revision = git('rev-parse', 'HEAD');
my $expected = $root.add('tools/red-revision').slurp.trim;
temp %*ENV<RED_SOURCE> = $checkout.Str;
my $process = run 'sh', $root.add('tools/test.sh').Str, :out, :err;
my $out = $process.out.slurp-rest;
my $err = $process.err.slurp-rest;
is $process.exitcode, 1, 'runner rejects a different Red revision';
ok $err.contains("expected $expected, got $revision"), 'error identifies expected and actual revisions';
is $out, '', 'runner stops before running tests';
is git('status', '--porcelain'), '', 'rejected checkout remains unchanged';
done-testing;
