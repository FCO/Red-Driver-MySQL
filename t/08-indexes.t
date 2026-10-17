use Test;
use Red::Driver::MySQL;
use Red::AST::CreateIndex;
use Red::AST::Function;
use Red::AST::Value;
use Red::AST::Infixes;

my $driver = Red::Driver::MySQL.CREATE;
my $*RED-DB = $driver;
sub fingerprint(Str $sql) { $driver.index-key-fingerprint($sql) }

subtest 'index DDL is local, quoted, ordered and unbound', {
    my $column = Red::AST::IndexColumn.new(:name('odd`column'), :value-type(Str));
    my $lower = Red::AST::Function.new(:func<LOWER>, :args[$column], :returns(Str));
    my $index = Red::AST::CreateIndex.new(:table('odd`table'), :name('odd`index'),
        :logical-name<logical>, :unique, :keys[$column, $lower]);
    my $sql = $driver.translate($index);
    is $sql.key, 'CREATE UNIQUE INDEX `odd``index` ON `odd``table` '
        ~ '(`odd``column`, (LOWER(`odd``column`)))', 'inherited DDL keeps identifiers and key order';
    is $sql.value.elems, 0, 'no DDL parameters';
    throws-like {
        $driver.index-key(Red::AST::Sum.new($column, ast-value(1), :bind-right))
    }, X::Red::Index, 'bound DDL is rejected';
};

subtest 'catalog normalization preserves expression meaning', {
    is fingerprint('LOWER(`email`)'), fingerprint('lcase((email))'), 'LOWER synonym';
    is fingerprint('SUBSTRING(`email`, (0 + 1), 2)'),
        fingerprint('substr(email, (0+1), 2)'), 'SUBSTR synonym';
    is fingerprint(q[replace(`email`, 'A', 'B')]),
        fingerprint(q[replace(`email`,_utf8mb4\'A\',_utf8mb4\'B\')]),
        'catalog literal escaping and default charset';
    my $catalog-unicode = '雪'.encode('utf8').decode('latin-1');
    is fingerprint(q[replace(`email`, '雪', 'B')]),
        fingerprint(q[replace(`email`,_utf8mb4\'] ~ $catalog-unicode ~ q[\',_utf8mb4\'B\')]),
        'catalog UTF-8 literal bytes';
    is fingerprint('cast(`email` AS CHAR(40))'),
        fingerprint('cast(`email` as char(40) charset utf8mb4)'), 'default CHAR charset';
    is fingerprint('cast(`email` AS CHAR(40) CHARACTER SET utf8mb4)'),
        fingerprint('cast(`email` as char(40) charset utf8mb4)'), 'charset clause spelling';
    for [q[replace(email, 'A', 'B')], q[replace(email, 'a', 'B')]],
        [q[replace(email, 'substring ( ::text', '')], q[replace(email, 'substr ( ', '')]],
        ['`Email`', '`email`'], ['`a``b`', '`ab`'],
        ['(a + b) * c', 'a + (b * c)'],
        ['cast(id AS CHAR(40))', 'id'],
        ['cast(email AS CHAR(40))', 'cast(email AS CHAR(41))'],
        ['cast(email AS CHAR(40))', 'cast(email AS CHAR(40) charset latin1)'],
        ['email COLLATE utf8mb4_bin', 'email COLLATE utf8mb4_0900_ai_ci'],
        ['email(10)', 'email'], ['email DESC', 'email'],
        [q[_latin1'A'], q[_utf8mb4'A']] -> @pair {
        isnt fingerprint(@pair[0]), fingerprint(@pair[1]), "distinguish {@pair.raku}";
    }
};

class CatalogRows {
    has @.rows;
    has $.end;
    method row { @!rows ?? @!rows.shift !! $!end }
}
class CatalogDriver is Red::Driver::MySQL {
    has $.result is rw;
    has $.sql is rw;
    has @.parameters;
    method execute($sql, *@bind) {
        $!sql = $sql;
        @!parameters = @bind;
        $!result
    }
}
sub row(Str $name, Str :$column = 'email', :$expression = Any,
    :$prefix = Any, Str :$order = 'A', Str :$type = 'BTREE',
    Str :$visible = 'YES', Int :$non-unique = 1) {
    %( :$name, :non_unique($non-unique), :column_name($column), :$expression,
        :sub_part($prefix), :ordering($order), :index_type($type), :is_visible($visible) )
}
subtest 'catalog groups keys and preserves incompatible definitions', {
    my $catalog = CatalogDriver.CREATE;
    $catalog.result = CatalogRows.new(:rows[
        row('PRIMARY', :column<id>, :non-unique(0)),
        row('composite', :column<account_id>),
        row('composite', :column(Str), :expression('lower(`email`)'.encode)),
        row('descending', :order<D>), row('fulltext', :type<FULLTEXT>),
        row('invisible', :visible<NO>), row('prefix', :prefix(10)),
        row('unknown', :column(Str)),
    ], :end(IterationEnd));
    my @indexes = $catalog.indexes-for-table("odd' table");
    isa-ok @indexes.Array, Array;
    is-deeply $catalog.parameters.Array, ["odd' table"], 'table name stays bound';
    like $catalog.sql, /'TABLE_SCHEMA = DATABASE()'/, 'current schema';
    like $catalog.sql, /'ORDER BY INDEX_NAME, SEQ_IN_INDEX'/, 'ordered catalog';
    is @indexes.elems, 7, 'one entry per index';
    ok @indexes[0]<unique>, 'PRIMARY is a unique catalog entry';
    is-deeply @indexes[1]<keys>.map(&fingerprint).Array,
        ['`account_id`', 'lower(`email`)'].map(&fingerprint).Array,
        'mixed composite preserves order and decodes expression buffers';
    is-deeply @indexes[2]<keys>, ['`email` DESC'], 'descending key retained';
    nok @indexes[2]<valid>, 'descending index cannot satisfy an ascending declaration';
    nok @indexes[3]<valid>, 'FULLTEXT is incompatible';
    nok @indexes[4]<valid>, 'invisible index is incompatible';
    is-deeply @indexes[5]<keys>, ['`email`(10)'], 'prefix length retained';
    nok @indexes[6]<valid>, 'unknown expression is incompatible';
    nok @indexes.grep(*.<partial>).elems, 'incompatibility is not a WHERE predicate';
    $catalog.result = CatalogRows.new;
    is-deeply $catalog.indexes-for-table('missing'), [], 'empty end-of-rows is supported';
};
done-testing;
