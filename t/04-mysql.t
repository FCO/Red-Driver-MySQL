use Test;
use Red:api<2>;
use Red::Type::Json;
use Red::AST::Insert;
use Red::AST::Value;

plan :skip-all('Set RED_DATABASE to a disposable MySQL database for integration tests')
    unless %*ENV<RED_DATABASE>;
my @conf = %*ENV<RED_DATABASE>.split(' ');
my $name = @conf.shift;
my $*RED-DB = database $name,
    |@conf.map({ my ($key, $value) = .split('=', 2); $key => val $value }).Hash;

model OnlySerial { has Int $.id is serial }
model NaturalKey { has Str $.id is id; has Str $.value is column }
model CompositeKey { has Int $.a is id; has Str $.b is id; has Str $.value is column }
model MySQLJson { has Int $.id is serial; has Json $.value is column{ :nullable } }
schema(OnlySerial, NaturalKey, CompositeKey, MySQLJson).drop.create;

is OnlySerial.^create.id, 1, 'empty insert retrieves generated id';
is OnlySerial.^create.id, 2, 'generated id comes from the current session';
my $natural = NaturalKey.^create(:id<alpha>, :value("back\\slash and 'quote"));
is $natural.id, 'alpha', 'insert with a supplied string id';
is $natural.value, "back\\slash and 'quote", 'bound strings round trip';
my $composite = CompositeKey.^create(:2a, :b<bravo>, :value<test>);
is $composite.a, 2, 'first composite key';
is $composite.b, 'bravo', 'second composite key';

MySQLJson.^create(:value{ 'dotted.key' => 42 });
is MySQLJson.^all.map({ .value{'dotted.key'} }).head, 42, 'quoted JSON object keys';

my $transaction = $*RED-DB.begin;
$transaction.execute('INSERT INTO only_serial () VALUES ()');
$transaction.rollback;
is OnlySerial.^all.elems, 2, 'rollback uses the same connection';
$transaction = $*RED-DB.begin;
$transaction.execute('INSERT INTO only_serial () VALUES ()');
$transaction.commit;
is OnlySerial.^all.elems, 3, 'commit persists the transaction';

my $reader = $*RED-DB.schema-reader;
ok $reader.tables-names.first(* eq 'natural_key').defined, 'list tables in the current database';
my $definition = $reader.table-definition('composite_key');
is $definition.name, 'composite_key', 'read information_schema table definition';
is $definition.columns.grep(*.pk).elems, 2, 'read composite primary key';
my @indexes = $reader.indexes-of('composite_key');
is-deeply @indexes.first(*.<primary>)<columns>, ['a', 'b'], 'ordered index columns';
nok $reader.table-definition('missing_table').exists, 'report missing tables';

throws-like { NaturalKey.^create(:id<alpha>, :value<duplicate>) },
    X::Red::Driver::Mapped::Unique, 'map MySQL duplicate key errors';
throws-like { NaturalKey.^create-table }, X::Red::Driver::Mapped::TableExists,
    'map MySQL table exists errors';
is $*RED-DB.execute('SELECT @@FOREIGN_KEY_CHECKS AS enabled').row<enabled>, 1,
    'schema drop restores foreign key checks';

subtest 'prepared inserts can be executed again', {
    my $statement = $*RED-DB.prepare(Red::AST::Insert.new(:into(OnlySerial))).head;
    $statement.execute;
    my $first = $statement.row;
    ok $first<id>.defined, 'first inserted id';
    nok $statement.row.defined, 'insert result is exhausted';
    $statement.execute;
    my $second = $statement.row;
    ok $second<id>.defined, 'second inserted id';
    isnt $first<id>, $second<id>, 'new execution retrieves its own row';
    nok $statement.row.defined, 'second result is exhausted';
    my $natural-statement = $*RED-DB.prepare(Red::AST::Insert.new(:into(NaturalKey),
        :values(id => ast-value('prepared-one'), value => ast-value('original')))).head;
    $natural-statement.execute;
    is $natural-statement.row<id>, 'prepared-one', 'original natural key';
    my @binds = $natural-statement.binds.map({ $_ eq 'prepared-one' ?? 'prepared-two' !! 'changed' });
    $natural-statement.execute(|@binds);
    my $row = $natural-statement.row;
    is $row<id>, 'prepared-two', 'readback uses overridden natural key bind';
    is $row<value>, 'changed', 'readback uses current values';
};

subtest 'four-byte UTF-8 round trips', {
    my $value = "ação 😀 back\\slash and 'quote";
    my $row = NaturalKey.^create(:id<unicode>, :$value);
    is $row.value, $value, 'bound value';
    is NaturalKey.^load('unicode').value, $value, 'stored value';
    is $*RED-DB.execute('SELECT ' ~ $*RED-DB.translate(ast-value($value)).key ~ ' AS value').row<value>,
        $value, 'native quoting agrees with connection charset';
    is MySQLJson.^create(:value{ emoji => '😀' }).value<emoji>, '😀', 'JSON unicode';
};

subtest 'JSON null differs from SQL NULL', {
    my $table = $*RED-DB.table-name-wrapper(MySQLJson.^table);
    for Any, Nil -> $value {
        my $row = MySQLJson.^create(:$value);
        is $*RED-DB.execute("SELECT JSON_TYPE(value) AS kind FROM $table WHERE id = ?", $row.id).row<kind>,
            'NULL', 'undefined JSON value is JSON null';
    }
    my $row = MySQLJson.^create(:value(Json));
    ok $*RED-DB.execute("SELECT value IS NULL AS missing FROM $table WHERE id = ?", $row.id).row<missing>,
        'Json type object is SQL NULL';
    $row = MySQLJson.^create;
    is $*RED-DB.execute("SELECT JSON_TYPE(value) AS kind FROM $table WHERE id = ?", $row.id).row<kind>,
        'NULL', 'implicit Any default follows Red JSON null semantics';
};

subtest 'foreign key checks restored after failed drop', {
    for 1, 0 -> $enabled {
        $*RED-DB.execute("SET FOREIGN_KEY_CHECKS = $enabled");
        dies-ok { $*RED-DB.execute('DROP TABLE missing_mysql_regression_table') }, 'drop fails';
        is $*RED-DB.execute('SELECT @@FOREIGN_KEY_CHECKS AS enabled').row<enabled>,
            $enabled, 'prior setting preserved';
    }
    $*RED-DB.execute('SET FOREIGN_KEY_CHECKS = 1');
};
done-testing;
