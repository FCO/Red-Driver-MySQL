use Test;
use JSON::Fast;

my %meta = from-json($?FILE.IO.parent.parent.add('META6.json').slurp);
my @red-deps = %meta<depends>.grep({ .starts-with('Red:') });

is @red-deps.elems, 1, 'exactly one Red runtime dependency';
ok index(@red-deps[0], 'ver<0.2.10+>') >= 0,
    "Red dependency declares a minimum version: {@red-deps[0]}";
ok index(@red-deps[0], 'api<2>') >= 0,
    'Red dependency keeps the api<2> requirement';

my $minimum = Version.new('0.2.10+');
ok Version.new('0.2.13') ~~ $minimum, 'newer Red releases satisfy the constraint';
nok Version.new('0.2.7') ~~ $minimum, 'Red 0.2.7 is rejected by the constraint';

done-testing;
