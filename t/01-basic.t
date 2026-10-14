use v6.c;
use Test;
use Red::Driver::MySQL;
use Red;
use Red::AST::Insert;
use Red::AST::Unary;
use Red::AST::Value;
use Red::Type::Json;

# Translation tests do not need a server or a native MySQL client library.
my $driver = Red::Driver::MySQL.CREATE;
my $*RED-DB = $driver;

model Defaults { has Int $.id is serial }
model Truth { has Int $.number is column; has Str $.text is column }
my %columns = Truth.^columns.map({ .column.name => .column });

is $driver.table-name-wrapper('a`b'), '`a``b`', 'escape backticks in identifiers';
is $driver.translate(Red::AST::Insert.new(:into(Defaults))).key,
    'INSERT INTO `defaults` () VALUES ()', 'insert using database defaults';
is $driver.translate(ast-value(True)).key, '1', 'boolean SQL literal';
is $driver.translate(ast-value(False), 'bind').key, '?', 'boolean parameters stay bound';
is $driver.translate(ast-value(False), 'update-rval').key, '?', 'boolean updates stay bound';
for <bind update-rval> -> $context {
    my $translated = $driver.translate(ast-value("back\\slash and 'quote"), $context);
    is $translated.key, '?', "string placeholder in $context";
    is-deeply $translated.value.Array, ["back\\slash and 'quote"], "string bind retained in $context";
}
is $driver.translate(Red::AST::Not.new(%columns<number>)).key,
    '(`truth`.`number` = 0 OR `truth`.`number` IS NULL)', 'numeric falsiness uses MySQL equality';
is $driver.translate(Red::AST::Not.new(%columns<text>)).key,
    "(`truth`.`text` = '' OR `truth`.`text` IS NULL)", 'string falsiness uses MySQL equality';
is $driver.translate(ast-value('{"a":1}', :type(Json))).key,
    q[CAST('{"a":1}' AS JSON)], 'MySQL JSON cast';
is $driver.default-type-for(%columns<number>), 'integer', 'integer type inherited from CommonSQL';
is $driver.default-type-for-type(Num), 'real', 'numeric type inherited from CommonSQL';
is $driver.default-type-for-type(DateTime), 'varchar(32)', 'datetime type inherited from CommonSQL';
is $driver.default-type-for(%columns<text>), 'varchar(255)', 'MySQL string default';
is $driver.type-for-sql('bigint unsigned'), 'Int', 'native MySQL integer type';
is $driver.type-for-sql('decimal(10,2)'), 'Num', 'native MySQL decimal type';
nok $driver.should-drop-cascade, 'MySQL does not implement DROP CASCADE';

my $duplicate = X::DBDish::DBError.new(:driver-name<mysql>, :code(1062),
    :native-message("Duplicate entry 'foo' for key 'person.name'"));
isa-ok $driver.map-exception($duplicate), X::Red::Driver::Mapped::Unique;
is-deeply $driver.map-exception($duplicate).fields.List, ('person.name',), 'duplicate index retained';
my $exists = X::DBDish::DBError.new(:driver-name<mysql>, :code(1050),
    :native-message("Table 'person' already exists"));
is $driver.map-exception($exists).table, 'person', 'map MySQL table exists error';

done-testing;
