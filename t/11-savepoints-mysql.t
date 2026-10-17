use Test;
use Red:api<2>;

plan :skip-all('Set RED_DATABASE to a disposable MySQL database for integration tests')
    unless %*ENV<RED_DATABASE>;
my @conf = %*ENV<RED_DATABASE>.split(' ');
my $name = @conf.shift;
my $*RED-DB = database $name,
    |@conf.map({ my ($k, $v) = .split('=', 2); $k => val $v }).Hash;
my $*RED-FALLBACK = False;

model SavepointRow {
    has Int $.id is serial;
    has Str $.label is column is unique;
}
schema(SavepointRow).drop.create;
sub labels { SavepointRow.^all.sort(*.id).map(*.label).Seq.Array }
# Exercise the low-level driver API without starting an ORM transaction around
# each insert: MySQL BEGIN would end the manually opened transaction.
sub insert-label(Str $label) {
    $*RED-DB.execute('INSERT INTO `savepoint_row` (`label`) VALUES (?)', $label);
}

subtest 'quoted markers roll back repeatedly and release without committing', {
    my $transaction = $*RED-DB.begin;
    LEAVE $transaction.rollback;
    insert-label('outer');
    my $marker = 'odd` marker"; --';
    ok $transaction.savepoint($marker) === $transaction, 'savepoint returns the driver';
    for ^2 -> $attempt {
        insert-label("discard-$attempt");
        ok $transaction.rollback-to-savepoint($marker) === $transaction,
            'rollback returns the driver';
        is-deeply labels(), ['outer'], 'rollback keeps the marker and preceding work';
    }
    ok $transaction.release-savepoint($marker) === $transaction, 'release returns the driver';
    insert-label('after-release');
    is-deeply labels(), ['outer', 'after-release'], 'surrounding transaction remains usable';
    dies-ok { $transaction.rollback-to-savepoint($marker) }, 'released marker raises an error';
};
is-deeply labels(), [], 'outer rollback also undoes work before the released marker';

subtest 'savepoint recovers after a uniqueness violation', {
    my $transaction = $*RED-DB.begin;
    LEAVE $transaction.rollback;
    insert-label('kept');
    $transaction.savepoint('recover');
    throws-like { insert-label('kept') }, X::Red::Driver::Mapped::Unique,
        'constraint error retains its mapped type';
    lives-ok { $transaction.rollback-to-savepoint('recover') }, 'rollback after failed statement';
    insert-label('recovered');
    $transaction.release-savepoint('recover');
    is-deeply labels(), ['kept', 'recovered'], 'connection works after recovery';
};
is-deeply labels(), [], 'recovery test leaves no committed writes';
done-testing;
