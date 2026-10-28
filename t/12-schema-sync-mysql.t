use Test;
use Red;
use Red::Cli::Column;
plan :skip-all('Set RED_DATABASE to a disposable MySQL database')
    unless %*ENV<RED_DATABASE>;
plan :skip-all('Schema sync metadata requires the corresponding Red API')
    unless Red::Cli::Column.^can('auto-increment');
my @conf = %*ENV<RED_DATABASE>.split(' ');
my $name = @conf.shift;
my $*RED-DB = database $name, |@conf.map({
    my ($k,$v) = .split('=',2); $k => val($v)
}).Hash;
$*RED-DB.execute(q:to/SQL/);
    CREATE TABLE sync_metadata_parent (
        id INTEGER PRIMARY KEY AUTO_INCREMENT,
        a VARCHAR(16), b VARCHAR(16), UNIQUE KEY sync_pair (a,b)
    )
    SQL
$*RED-DB.execute(q:to/SQL/);
    CREATE TABLE sync_metadata_child (
        parent_id INTEGER,
        CONSTRAINT sync_parent_fk FOREIGN KEY (parent_id) REFERENCES sync_metadata_parent(id)
    )
    SQL
my $reader = $*RED-DB.schema-reader;
my $table = $reader.table-definition('sync_metadata_parent');
ok $table.columns.first(*.name eq 'id').auto-increment,
    'Catalog metadata preserves AUTO_INCREMENT';
is-deeply $table.constraints.Array, [<a b>.Array,],
    'Catalog metadata preserves ordered composite UNIQUE columns';
my @dependencies = $reader.column-dependencies('sync_metadata_parent','id');
ok @dependencies.first(* eq 'PRIMARY').defined, 'Primary key dependency is visible';
ok @dependencies.first(* eq 'sync_parent_fk').defined, 'Incoming FK dependency is visible';
ok $reader.column-dependencies('sync_metadata_parent','a').first(* eq 'sync_pair').defined,
    'Composite index dependency is visible';
done-testing;
