use Test;
use Red:api<2>;
use Red::Type::Json;
use Red::AST::Value;

plan :skip-all('Set RED_DATABASE to a disposable MySQL database for integration tests')
    unless %*ENV<RED_DATABASE>;
my $*RED-FALLBACK = False;
my @conf = %*ENV<RED_DATABASE>.split(' ');
my $name = @conf.shift;
my $*RED-DB = database $name,
    |@conf.map({ my ($k, $v) = .split('=', 2); $k => val $v }).Hash;

model QueryRow {
    has Int $.id is serial;
    has Int $.value is column;
    has Str $.text is column;
}
model JsonRow {
    has Int $.id is serial;
    has Json $.data is rw is column;
    has Json $.optional is column{ :nullable };
    has Str $.key is column;
    has Int $.index is column;
}
schema(QueryRow, JsonRow).drop.create;
QueryRow.^create(:value($_), :text("雪😀$_")) for ^10;
sub rows { QueryRow.^all.sort(*.id) }

subtest 'offsets and derived projections', {
    is-deeply rows.skip(2).Seq.map(*.value).Array, [|(2..9)], 'skip without head';
    is-deeply rows.skip(0).Seq.map(*.value).Array, [|^10], 'zero offset';
    is-deeply rows.skip(100).Seq.Array, [], 'offset past the last row';
    is-deeply rows.map(*.value).skip(2).grep(* > 0).Seq.Array, [|(2..9)],
        'filter after projected offset';
    is-deeply rows.map(*.value).skip(0).grep(* > 0).Seq.Array, [|(1..9)],
        'projected zero offset';
    is-deeply rows.map(*.value).skip(100).grep(* > 0).Seq.Array, [],
        'derived offset beyond the last row';
    is-deeply rows.skip(2).head(3).Seq.map(*.value).Array, [2,3,4], 'explicit limit';
    is-deeply rows.map(*.value).skip(2).head(3).grep(* > 2).Seq.Array, [3,4],
        'explicit limit across a projection boundary';
};

subtest 'bound text across tail and pagination boundaries', {
    my Str $suffix = 'suffix';
    my Str $prefix = 'prefix: ';
    my $query = rows.map(*.value).sort({ $_ ~ $suffix }).tail(3).map({ $prefix ~ $_ });
    is-deeply $query.Seq.Array, ['prefix: 7', 'prefix: 8', 'prefix: 9'],
        'numeric values become text';
    ok $query.Seq.all ~~ Str, 'projection values are Str';
    my ($sql, @bind) := $*RED-DB.translate($query.ast).kv;
    is-deeply @bind.Array, [$prefix, $suffix, $suffix], 'outer and inner parameters retain order';
    my $statement = $*RED-DB.prepare($sql);
    $statement.execute(|@bind);
    ok $statement.row.values.first(* ~~ Str).defined, 'raw result is already textual';
    my Str $unicode = 'ação 😀: ';
    my Str $end = ' 雪';
    my $strings = rows.map(*.text).skip(2).head(5).tail(2).map({ $unicode ~ $_ ~ $end });
    is-deeply $strings.Seq.Array, ['ação 😀: 雪😀5 雪', 'ação 😀: 雪😀6 雪'],
        'Unicode string projection crosses pagination and tail';
    ok $strings.Seq.all ~~ Str, 'Unicode results are Str';
    my $bytes = Buf.new(0, 255, 128, 65);
    $*RED-DB.execute('CREATE TABLE query_binary (bytes BLOB)');
    $*RED-DB.execute(q[INSERT INTO query_binary (bytes) VALUES (X'00ff8041')]);
    my $binary = $*RED-DB.execute('SELECT bytes FROM query_binary').row<bytes>;
    isa-ok $binary, Blob, 'genuine binary results remain binary';
    is-deeply $binary.list.Array, $bytes.list.Array, 'binary bytes are unchanged';
};

subtest 'JSON presence counts and containment', {
    JsonRow.^create(:data{ no => False, null => Any, items => [Any,20],
        'a".雪' => { x => 1 }, object => { a => 1, b => 2 } },
        :key('a".雪'), :index(-1));
    for <no null> -> $key {
        is JsonRow.^all.grep({ .data{$key}:exists }).elems, 1, "$key exists";
        is JsonRow.^all.map({ .data{$key}.elems }).head, 1, "$key is one scalar";
    }
    is JsonRow.^all.grep({ .data<missing>:!exists }).elems, 1, 'missing is absent';
    is JsonRow.^all.grep({ .optional<missing>:!exists }).elems, 1, 'SQL NULL has no paths';
    is JsonRow.^all.map(*.optional.elems).head, 1, 'root SQL NULL is one value';
    is JsonRow.^all.map(*.data<missing>).head(1).map(*.elems).head, 0,
        'missing path presence crosses a projection boundary';
    is JsonRow.^all.map(*.data<null>).head(1).map(*.elems).head, 1,
        'JSON null presence crosses a projection boundary';
    is JsonRow.^all.map({ .data<items>[.index] }).head, 20, 'dynamic negative index';
    is JsonRow.^all.grep({ .data{.key}:exists }).elems, 1, 'dynamic special key existence';
    is JsonRow.^all.grep({ .data{.key}.contains({ x => 1 }) }).elems, 1,
        'dynamic object containment';
    is-deeply JsonRow.^all.map({ .data<items>.contains(20) }).head.so, True,
        'containment selected as boolean';
    is JsonRow.^all.grep({ .data<items>.contains('20') }).elems, 0,
        'numeric and text scalars differ';
    is JsonRow.^all.map(*.data<object>.elems).head, 2, 'object members';
    is JsonRow.^all.map(*.data<items>.elems).head, 2, 'array members';
    is JsonRow.^all.map(*.data<items>[8].elems).head, 0, 'out-of-range member';
};
done-testing;
