use Test;
use Red:api<2>;
use Red::AST::Function;
use Red::AST::Value;
need DBDish::mysql::StatementHandle;

plan :skip-all('Set RED_DATABASE to a disposable MySQL database for integration tests')
    unless %*ENV<RED_DATABASE>;
my @conf = %*ENV<RED_DATABASE>.split(' ');
my $name = @conf.shift;
my $*RED-DB = database $name,
    |@conf.map({ my ($k,$v) = .split('=',2); $k => val $v }).Hash;
my $*RED-FALLBACK = False;
sub quoted(Str $name) { $*RED-DB.table-name-wrapper($name) }
sub drop-index($index) {
    $*RED-DB.execute('DROP INDEX ' ~ quoted($index.name) ~ ' ON ' ~ quoted($index.table));
}

model ExpressionIndexes {
    has Int $.id is serial;
    has Int $.account is indexed<account-email>;
    has Str $.email is indexed('account-email', { .lc });
    has Str $.code is unique;
    has Str $.café is indexed{ .lc };
    has $.prefix is index{ .email.substr(0, 2) };
    has $.literal is index{ Red::AST::Function.new(:func<REPLACE>,
        :args[.email, ast-value("A'雪\\x"), ast-value('B')], :returns(Str)) };
}
subtest 'real mixed and functional index catalogs', {
    lives-ok { schema(ExpressionIndexes).drop.create }, 'schema creates declarations';
    lives-ok { ExpressionIndexes.^create-indexes }, 'repetition handles literals and Unicode';
    lives-ok { ExpressionIndexes.^create-indexes(:with($*RED-DB)) }, 'explicit driver';
    lives-ok { ExpressionIndexes.^create-table(:if-not-exists) }, 'existing table';
    my @catalog = $*RED-DB.indexes-for-table(ExpressionIndexes.^table);
    is @catalog.elems, 6, 'PRIMARY, legacy unique, and four declared indexes';
    my $mixed = ExpressionIndexes.^indexes.first(*.logical-name eq 'account-email');
    my $found = @catalog.first(*.<name> eq $mixed.name);
    is-deeply $found<keys>.map({ $*RED-DB.index-key-fingerprint($_) }).Array,
        ['`account`', 'lower(`email`)'].map({ $*RED-DB.index-key-fingerprint($_) }).Array,
        'ordered mixed keys';
    for ExpressionIndexes.^indexes.grep({ !.inline }) -> $index {
        my $entry = @catalog.first(*.<name> eq $index.name);
        is-deeply $entry<keys>.map({ $*RED-DB.index-key-fingerprint($_) }).Array,
            $index.keys.map({ $*RED-DB.index-key-fingerprint($*RED-DB.index-key($_)) }).Array,
            "actual definition matches {$index.logical-name}";
    }
    my @statistics = $*RED-DB.index-catalog-rows($*RED-DB.execute(
        'SELECT EXPRESSION AS expression FROM information_schema.STATISTICS '
        ~ 'WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND EXPRESSION IS NOT NULL',
        ExpressionIndexes.^table));
    is @statistics.elems, 4, 'functional expressions exist in STATISTICS';
    my @show = $*RED-DB.index-catalog-rows($*RED-DB.execute(
        'SHOW INDEX FROM ' ~ quoted(ExpressionIndexes.^table)));
    is @show.elems, 7, 'SHOW INDEX includes each key of the composite';
    # SHOW CREATE TABLE has no prepare-time result metadata. Use DBIish's text
    # protocol explicitly for this independent verification of the catalog.
    my $dbh = $*RED-DB.dbh;
    my $client = $dbh.^attributes.first(*.name eq '$!mysql-client').get_value($dbh);
    my $show-create = DBDish::mysql::StatementHandle.new(:parent($dbh), :mysql-client($client),
        :statement('SHOW CREATE TABLE ' ~ quoted(ExpressionIndexes.^table)), :RaiseError);
    $show-create.execute;
    my $create = $show-create.row(:hash);
    like $create{'Create Table'}, /:i 'lower'/, 'SHOW CREATE TABLE contains expressions';
    my $stored = "A'雪\\x";
    my $record = ExpressionIndexes.^create(:account(1), :email($stored), :code<C1>, :café<Mixed>);
    is $record.email, $stored, 'functional indexes do not change stored values';
    $*RED-DB.execute('CREATE TABLE null_text_probe (value TEXT NULL)');
    $*RED-DB.execute('INSERT INTO null_text_probe VALUES (NULL)');
    nok $*RED-DB.execute('SELECT value FROM null_text_probe').row<value>.defined,
        'nullable textual BLOB metadata does not decode a type object';
};

model ConflictIndexes {
    has Int $.id is serial;
    has Str $.pending is indexed;
    has Str $.email is indexed<ordered>;
    has Int $.account is indexed<ordered>;
}
subtest 'catalog conflicts are rejected before any pending DDL', {
    my $index = ConflictIndexes.^indexes.first(*.logical-name eq 'ordered');
    my $pending = ConflictIndexes.^indexes.first(*.logical-name eq 'pending');
    my $table = quoted($index.table);
    for '(`account`, `email`)', '(`email`(10), `account`)',
        '(`email` DESC, `account`)', '(`email`, `account`) INVISIBLE',
        '((LOWER(`email`)), `account`)', 'UNIQUE' -> $definition {
        schema(ConflictIndexes).drop.create;
        drop-index($pending);
        drop-index($index);
        my $unique = $definition eq 'UNIQUE' ?? ' UNIQUE' !! '';
        my $keys = $unique ?? '(`email`, `account`)' !! $definition;
        $*RED-DB.execute("CREATE$unique INDEX " ~ quoted($index.name) ~ " ON $table $keys");
        throws-like { ConflictIndexes.^create-indexes }, X::Red::Index,
            "reject incompatible definition $definition";
        nok $*RED-DB.indexes-for-table($index.table).first(*.<name> eq $pending.name).defined,
            'no pending index was created';
    }
};

model LegacyUniqueIndexes {
    has Int $.id is serial;
    has Str $.code is unique;
    has Str $.other is column;
}
subtest 'legacy constraints and missing uniqueness', {
    my $table = quoted(LegacyUniqueIndexes.^table);
    $*RED-DB.execute("CREATE TABLE $table (id INT PRIMARY KEY, code VARCHAR(40), "
        ~ 'other VARCHAR(40), UNIQUE KEY old_pair (code, other))');
    lives-ok { LegacyUniqueIndexes.^create-indexes }, 'composite unique does not satisfy individual';
    is $*RED-DB.indexes-for-table(LegacyUniqueIndexes.^table).elems, 3,
        'missing individual unique added';
    lives-ok { LegacyUniqueIndexes.^create-indexes }, 'individual uniqueness is reusable';
    $*RED-DB.execute("INSERT INTO $table VALUES (1, 'keep', 'one')");
    throws-like { $*RED-DB.execute("INSERT INTO $table VALUES (2, 'keep', 'two')") },
        X::Red::Driver::Mapped::Unique, 'individual unique enforced';
    $*RED-DB.execute("DROP TABLE $table");
    $*RED-DB.execute("CREATE TABLE $table (id INT PRIMARY KEY, code VARCHAR(40), "
        ~ 'other VARCHAR(40), UNIQUE KEY old_code (code))');
    lives-ok { LegacyUniqueIndexes.^create-indexes }, 'legacy individual unique reused';
    is $*RED-DB.indexes-for-table(LegacyUniqueIndexes.^table).elems, 2, 'no duplicate unique';
    is-deeply $*RED-DB.indexes-for-table("missing' OR 1=1 --"), [],
        'catalog filters the table name as a parameter';
};
done-testing;
