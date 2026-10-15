use Test;
use Red:api<2>;
use Red::Driver::MySQL;
use Red::AST::Select;
use Red::AST::Update;
use Red::AST::Value;
use Red::AST::Infixes;
use Red::AST::JsonItem;
use Red::AST::JsonOperation;
use Red::Type::Json;

my $*RED-DB = Red::Driver::MySQL.CREATE;
model TranslationRow {
    has Int $.id is serial;
    has Int $.value is column;
    has Json $.data is column;
}
my %columns = TranslationRow.^columns.map({ .column.name => .column });

subtest 'offset without limit', {
    for 0, 2, 100 -> $offset {
        my $sql = $*RED-DB.translate(
            Red::AST::Select.new(:of(TranslationRow), :$offset)).key;
        like $sql, /'LIMIT' \s+ '18446744073709551615'/, "unbounded offset $offset";
        like $sql, /'OFFSET' \s+ $offset/, 'offset retained';
    }
    for 0, 3 -> $limit {
        my $sql = $*RED-DB.translate(
            Red::AST::Select.new(:of(TranslationRow), :2offset, :$limit)).key;
        like $sql, /'LIMIT' \s+ $limit/, 'explicit limit retained';
        nok $sql.contains('18446744073709551615'), 'no unbounded sentinel';
    }
    my $query = TranslationRow.^all.sort(*.id).map(*.value).skip(2).grep(* > 0);
    like $*RED-DB.translate($query.ast).key,
        /'LIMIT' \s+ '18446744073709551615' \s+ 'OFFSET' \s+ '2'/,
        'derived projection has valid pagination';
};

subtest 'JSON paths and operations retain binds', {
    my $item = Red::AST::JsonItem.new(%columns<data>, ast-value('a".雪'));
    my $exists = Red::AST::JsonOperation.new(:operation<exists>, :value($item));
    my $translation = $*RED-DB.translate($exists, 'where');
    like $translation.key, /'JSON_CONTAINS_PATH'/, 'path existence';
    is-deeply $translation.value.Array, [q[."a\".雪"]], 'special path stays bound';
    my $elems = $*RED-DB.translate(
        Red::AST::JsonOperation.new(:operation<elems>, :value($item)), 'select');
    is-deeply $elems.value.Array, [q[."a\".雪"], q[."a\".雪"]],
        'presence binds precede value binds';
    my $contains = $*RED-DB.translate(Red::AST::JsonOperation.new(
        :operation<contains>, :value($item), :argument(ast-value('{"x":1}', :type(Json)))));
    is-deeply $contains.value.Array, [q[."a\".雪"], '{"x":1}'],
        'containment source and argument bind order';
    is-deeply $*RED-DB.mysql-json-path(ast-value([ast-value('items'), ast-value(-1)])).value.Array,
        ['."items"', '[last-0]'], 'nested negative array index';
    my $key = Red::AST::Concat.new(ast-value('pre'), ast-value('fix'), :bind-left, :bind-right);
    my $dynamic = $*RED-DB.mysql-json-path($key);
    like $dynamic.key, /'JSON_QUOTE'/, 'dynamic object keys are quoted';
    is-deeply $dynamic.value.Array, ['pre', 'fix'], 'dynamic path bind order';
    my $index = Red::AST::Sum.new(%columns<value>, ast-value(-1), :bind-right);
    is-deeply $*RED-DB.mysql-json-path($index).value.Array, [-1, -1, -1],
        'dynamic negative index expressions repeat their binds in SQL order';
};

subtest 'JSON updates compose in SQL', {
    my $first = Red::AST::JsonItem.new(%columns<data>, ast-value('first'));
    my $second = Red::AST::JsonItem.new(%columns<data>, ast-value('second'));
    my $update = Red::AST::Update.new(:model(TranslationRow), :values[
        %columns<data> => ast-value('{}', :type(Json)),
        $first => ast-value(1),
        $second => ast-value(True),
    ]);
    my $translation = $*RED-DB.translate($update);
    is $translation.key.comb('JSON_SET(').elems, 2, 'both assignments are nested';
    is $translation.key.comb(' = ').elems, 1, 'one assignment to the JSON column';
    is-deeply $translation.value.Array, ['{}', '."first"', '."second"'],
        'replacement and paths retain their parameter order';
};

subtest 'text concatenation retains ordered parameters', {
    my $ast = Red::AST::Concat.new(ast-value('雪: '),
        Red::AST::Concat.new(ast-value(7), ast-value('😀'), :bind-left, :bind-right),
        :bind-left);
    my $translation = $*RED-DB.translate($ast, 'select');
    is $translation.key, 'CONCAT(?, CONCAT(?, ?))', 'nested concatenation';
    is-deeply $translation.value.Array, ['雪: ', 7, '😀'], 'nested bind order';
};
done-testing;
