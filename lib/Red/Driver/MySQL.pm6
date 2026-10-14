use DBIish;
need DBDish::mysql::Connection;
use Red::AST;
use Red::Driver;
use Red::Statement;
use Red::AST::Value;
use Red::AST::Select;
use Red::AST::Infix;
use Red::AST::Infixes;
use Red::AST::Function;
use Red::Driver::CommonSQL;
use Red::AST::LastInsertedRow;
use Red::AST::TableComment;
use Red::AST::JsonItem;
use Red::AST::JsonRemoveItem;
use Red::AST::DateTimeFuncs;
use X::Red::Exceptions;
use UUID;
use Red::SchemaReader;
use Red::Driver::MySQL::SchemaReader;
use Red::Type::Json;
use JSON::Fast;
unit class Red::Driver::MySQL does Red::Driver::CommonSQL;

has Str                       $!user;
has Str                       $!password;
has Str                       $!host;
has Int                       $!port;
has Str                       $!database;
has DBDish::mysql::Connection $.dbh;

#| Read tables, columns and indexes from the connected database.
method schema-reader { Red::Driver::MySQL::SchemaReader.new: :driver(self) }

submethod BUILD(
    DBDish::mysql::Connection :$!dbh,
    Str  :$!host = q<localhost>,
    Str  :$!user = "root",
    UInt :$!port = 3306,
    Str  :$!password,
    Str  :$!database!,
) {}

submethod TWEAK() {
    $!dbh //= DBIish.connect: "mysql",
        :$!database,
        |(:$!host     with $!host),
        |(:$!user     with $!user),
        |(:$!port     with $!port),
        |(:$!password with $!password),
    ;
    # DBIish currently selects utf8 (three-byte UTF-8) and has no public
    # charset setter. Use the native API so quoting and the server agree.
    $!dbh.protect-connection: {
        my $attribute = DBDish::mysql::Connection.^attributes.first(*.name eq '$!mysql-client');
        die 'DBIish MySQL native client is unavailable' unless $attribute;
        my $client = $attribute.get_value($!dbh);
        die "Cannot configure MySQL utf8mb4: { $client.mysql_error }"
            if $client.mysql_set_character_set('utf8mb4');
    };
}

sub insert-values(Red::AST::Insert $ast) {
    $ast.values.pairs.grep({
        .value.value.defined || (.value.column.DEFINITE
            && .value.column.attr.type ~~ Json && !(.value.value === Json))
    })
}

class Statement does Red::Statement {
    has Red::AST::Insert $.insert is rw;
    has Bool $!insert-pending = False;
    has %!insert-values;
    method stt-exec($stt, *@bind) {
        my @values = @bind || @!binds;
        $!insert-pending = False;
        $.driver.debug: @values;
        $stt.execute: |@values;
        if $!insert.DEFINITE {
            %!insert-values = insert-values($!insert).map(*.key) Z=> @values;
            $!insert-pending = True;
        }
        $stt
    }
    method stt-row($stt) {
        return $stt.row(:hash) unless $!insert.DEFINITE;
        return Nil unless $!insert-pending;
        $!insert-pending = False;
        my $insert = $!insert;
        my $of = $insert.into;
        my @keys = $of.^id».column;
        @keys = $of.^columns».column unless @keys;
        my @filters;
        for @keys -> $column {
            my $value = %!insert-values{$column.name};
            if $column.auto-increment && !$value.defined {
                @filters.push: Red::AST::Eq.new($column,
                    Red::AST::Function.new(:func<LAST_INSERT_ID>));
            } elsif $value.defined {
                @filters.push: Red::AST::Eq.new($column, ast-value($value), :bind-right);
            }
        }
        # MySQL has no INSERT RETURNING. Read back database defaults using the
        # generated serial or supplied key, including composite/non-numeric keys.
        die 'Cannot identify the inserted MySQL row' unless @filters;
        my $filter = @filters == 1 ?? @filters.head
            !! @filters.reduce({ Red::AST::AND.new($^a, $^b) });
        $.driver.execute(Red::AST::Select.new(:$of, :$filter, :1limit)).row
    }
}

multi method prepare(Red::AST::Insert $query) {
    return () if $*RED-DRY-RUN;
    my $translated = self.translate(self.optimize($query));
    my $statement = self.prepare($translated.key);
    $statement.predefined-bind;
    $statement.binds = $translated.value.map({ self.deflate($_) });
    $statement.insert = $query;
    ($statement,)
}

#| Prepare statement
multi method prepare(Str $query) {
    CATCH {
        default {
            self.map-exception($_).throw
        }
    }
    self.debug: $query;
    Statement.new: :driver(self), :statement($!dbh.prepare: $query);
}

# Red::Schema.drop can visit a referenced table before its children. Restore
# the session setting even if DROP fails; normal writes retain FK validation.
method execute($query, *@bind) {
    my &execute = {
        my @statements = self.prepare($query);
        (.execute(|@bind.map({ self.deflate($_) })) for @statements).tail
    };
    if $query ~~ Str && $query ~~ /^:i \s* DROP \s+ TABLE / {
        my $previous = $!dbh.execute('SELECT @@FOREIGN_KEY_CHECKS').row.head;
        LEAVE { $!dbh.execute("SET FOREIGN_KEY_CHECKS = $previous") }
        $!dbh.execute('SET FOREIGN_KEY_CHECKS = 0');
        return execute();
    }
    execute()
}

method stringify-json { True }

# A transaction must use the same session as the queries executed inside it.
method new-connection { self.clone }

#| Begin transaction
#| it's being overrided here because MySQL do not accept BEGIN on `prepare`
method begin {
    CATCH { default { self.map-exception($_).throw } }
    my $trans = self.new-connection;
    my $sql = "BEGIN";
    self.debug: $sql;
    $trans.dbh.execute: $sql;
    $trans
}

#| Table name wrapper
method table-name-wrapper($name) { '`' ~ $name.subst('`', '``', :g) ~ '`' }

multi method should-drop-cascade { False }

#| TODO Change Red to define the operator translation
multi method translate(Red::AST::Infix $_ where { .op eq "==" }, $context?) {
    my ($lstr, @lbind) := do given self.translate: .left,  .bind-left  ?? "bind" !! $context { .key, .value }
    my ($rstr, @rbind) := do given self.translate: .right, .bind-right ?? "bind" !! $context { .key, .value }

    "$lstr = $rstr" => [|@lbind, |@rbind]
}

#| TODO Change Red to translate AST instead of hardcoded string
multi method translate(Red::AST::Not $_ where { .value ~~ Red::Column and .value.attr.type !~~ Str }, $context?) {
    my ($val, @bind) := do given self.translate: .value, $context { .key, .value }
    "($val = 0 OR $val IS NULL)" => @bind
}

#| MySQL's syntax for inserting a row using only database defaults.
multi method translate(Red::AST::Insert $_ where { !insert-values($_) }, $context?) {
    "INSERT INTO { self.table-name-wrapper: .into.^table } () VALUES ()" => []
}

multi method translate(Red::AST::Insert $ast, $context?) {
    my @values = insert-values($ast);
    my @bind = @values.map({ self.wildcard-value(.value) });
    "INSERT INTO { self.table-name-wrapper($ast.into.^table) } ({
        @values.map({ self.table-name-wrapper(.key) }).join(', ')
    }) VALUES ({ (self.wildcard xx @values).join(', ') })" => @bind
}

multi method translate(Red::Column $_, $context?) {
    "{ self.table-name-wrapper(.model.^as) }.{ self.table-name-wrapper(.name) }" => []
}

multi method translate(Red::Column $_, 'where') {
    "{ self.table-name-wrapper(.class.^as) }.{ self.table-name-wrapper(.name) }" => []
}
multi method translate(Red::Column $_, 'create-table-column-name') { self.table-name-wrapper(.name) => [] }
multi method translate(Red::Column $_, 'unique') { self.table-name-wrapper(.name) => [] }
multi method translate(Red::Column $_, 'pk') { self.table-name-wrapper(.name) => [] }
multi method translate(Red::Column $_, 'update-lval') { self.table-name-wrapper(.name) => [] }

multi method translate(Red::Column $col, 'select', Str :$RED-OVERRIDE-COLUMN-AS-PREFIX) {
    my $value = do with $col.computation {
        my $*RED-INSIDE-COMPUTATION = True;
        self.translate($_, 'select')
    } else {
        "{ self.table-name-wrapper($col.model.^as) }.{ self.table-name-wrapper($col.name) }" => []
    };
    my $alias = ($RED-OVERRIDE-COLUMN-AS-PREFIX ?? "$RED-OVERRIDE-COLUMN-AS-PREFIX." !! '')
        ~ $col.attr-name;
    my $as = $col.computation.?type !~~ Positional
        && !(try $*RED-INSIDE-COMPUTATION)
        && ($col.computation || $col.name ne $col.attr-name || $RED-OVERRIDE-COLUMN-AS-PREFIX);
    ($value.key ~ ($as ?? ' AS ' ~ self.table-name-wrapper($alias) !! '')) => $value.value
}

multi method translate(Red::AST::Function $_ where { .func.uc eq 'RANDOM' }, $context?) {
    'RAND()' => []
}

multi method translate(Red::AST::Concat $_, $context?) {
    my $left = self.translate(.left, .bind-left ?? 'bind' !! $context);
    my $right = self.translate(.right, .bind-right ?? 'bind' !! $context);
    "CONCAT({ $left.key }, { $right.key })" => [|$left.value, |$right.value]
}

multi method translate(Red::AST::DateTimePart $_, $context?) {
    self.translate(Red::AST::Function.new(:func<DATE_FORMAT>,
        :args[.base, ast-value(.part.value)]), $context)
}

multi method translate(Red::AST::DateTimeToday $_, $context?) { 'CURRENT_DATE' => [] }

# Materialize subqueries that read the table being updated (MySQL error 1093).
multi method translate(Red::AST::Update $_, $context?) {
    my $*MYSQL-UPDATING = True;
    my @bind;
    my $assignments = .values.map({
        my $value = self.translate(ast-value($_), 'update');
        @bind.append: $value.value;
        $value.key
    }).join(', ');
    my $filter = .filter;
    if $filter.DEFINITE && $filter.tables.map({ .HOW.?join-on($_) }).any {
        $filter = Red::AST::In.new(.model.^id».column.head,
            Red::AST::Select.new(:of(.model.^specialise(.model.^id».column)), :$filter));
    }
    my $where = self.translate($filter);
    "UPDATE { self.table-name-wrapper(.into) } SET { $assignments }{
        $filter.DEFINITE ?? ' WHERE ' ~ $where.key !! ''
    }" => [|@bind, |$where.value]
}

multi method translate(Red::AST::Infix $_ where {
    .op eq 'IN' && .right ~~ Red::AST::Select && (try $*MYSQL-UPDATING)
}, $context?) {
    my $left = self.translate(.left, $context);
    my $right = self.translate(.right.as-select.clone(:limit(.right.limit // 18446744073709551615)));
    "{ $left.key } IN (SELECT * FROM ({ $right.key }) AS red_update)" =>
        [|$left.value, |$right.value]
}

multi method translate(Red::AST::Value $_ where .type ~~ Bool, $context? where { !.defined || $_ ne any(<bind update-rval>) }) {
    (.value ?? 1 !! 0) => []
}

multi method translate(Red::AST::Value $_ where { .type ~~ Json }, $context? where { !.defined || $_ ne "bind" }) {
    my $value = self.translate: ast-value(.get-value, :type(Str)), $context;
    "CAST({ $value.key } AS JSON)" => $value.value
}

multi method translate(Red::AST::Value $_ where { .type ~~ Str && .type !~~ Json },
    $context? where { !.defined || $_ ne any(<bind update-rval>) }) {
    my $value = .get-value;
    my $quoted = $!dbh.DEFINITE ?? $!dbh.quote($value)
        !! "'" ~ $value.subst('\\', '\\\\', :g).subst("'", "''", :g) ~ "'";
    $quoted => []
}

multi method prepare-json-path-item(Str $key) { '.' ~ to-json($key, :!pretty) }

multi method translate(Red::AST::So $_ where { .value ~~ Red::Column and .value.attr.type !~~ Str }, $context?) {
    my ($val, @bind) := do given self.translate: .value, $context { .key, .value }
    "($val <> 0 AND $val IS NOT NULL)" => @bind
}

multi method translate(Red::AST::Not $_ where { .value ~~ Red::Column and .value.attr.type ~~ Str }, $context?) {
    my ($val, @bind) := do given self.translate: .value, $context { .key, .value }
    "($val = '' OR $val IS NULL)" => @bind
}

multi method translate(Red::AST::So $_ where { .value ~~ Red::Column and .value.attr.type ~~ Str }, $context?) {
    my ($val, @bind) := do given self.translate: .value, $context { .key, .value }
    "($val <> '' AND $val IS NOT NULL)" => @bind
}

multi method translate(Red::AST::LastInsertedRow $_, $context?) {
    my $of     = .of;
    my $filter = $of.^id-filter: Red::AST::Function.new: :func<LAST_INSERT_ID>;
    self.translate(Red::AST::Select.new: :$of, :table-list[$of], :$filter, :1limit)
}

multi method translate(Red::Column $_, "column-auto-increment") { (.auto-increment ?? "AUTO_INCREMENT" !! "") => [] }

multi method translate(Red::Column $_, "column-comment") {
    (.comment.defined ?? 'COMMENT ' ~ self.translate(ast-value(.comment)).key !! '') => []
}

multi method translate(Red::AST::JsonRemoveItem $_, $context?) {
    self.translate:
            Red::AST::Function.new:
                    :func<JSON_REMOVE>,
                    :args[
                        .left,
                        ast-value('$' ~ self.prepare-json-path-item: .right.value)
                    ],
                    :returns(Json),
}

multi method translate(Red::AST::JsonItem $_, $context?) {
    self.translate:
            Red::AST::Function.new:
                    :func<JSON_EXTRACT>,
                    :args[
                        .left,
                        ast-value('$' ~ self.prepare-json-path-item: .right.value)
                    ],
                    :returns(Json),
}

multi method translate(Red::AST::Value $_ where { .type ~~ Pair and .value.key ~~ Red::AST::JsonItem}, "update") {
    my $value = Red::AST::Function.new:
            :func<JSON_SET>,
            :args[
                .value.key.left,
                ast-value('$' ~ self.prepare-json-path-item(.value.key.right.value)),
                .value.value
            ],
            :returns(Json),
    ;
    self.translate: ast-value(.value.key.left => $value), "update"
}

multi method translate(Red::AST::Minus $ast, "multi-select-op") { "EXCEPT" => [] }

method comment-on-same-statement { True }

multi method default-type-for-type(Str --> Str:D) { "varchar(255)" }
multi method default-type-for-type(Bool --> Str:D) { "integer" }
multi method default-type-for-type(Duration --> Str:D) { "real" }
multi method default-type-for-type(Instant --> Str:D) { "double" }
multi method deflate(Instant:D $value) { $value.to-posix.head.Num }
multi method default-type-for(Red::Column $ where .attr.type ~~ Positional --> Str:D) { 'json' }
multi method type-by-name('jsonb' --> 'json') {}
multi method wildcard-value(@values) { to-json @values }
multi method deflate(Positional:D $value) { to-json $value }
multi method inflate(Str $value, :@to!) {
    my @values = from-json $value;
    @to.of =:= Mu ?? @values !! Array[@to.of].new(@values.map({ @to.of.($_) }))
}

# CommonSQL already handles its portable type names. Normalize MySQL's native
# names (including sizes and UNSIGNED) for reverse engineering existing schemas.
multi method type-for-sql(Str:D $type) is default {
    given $type.lc.split(/ \s | '(' /).head {
        when <tinyint smallint mediumint int integer bigint bit year>.any { 'Int' }
        when <decimal numeric dec fixed float double real>.any { 'Num' }
        when <char varchar tinytext text mediumtext longtext enum set time>.any { 'Str' }
        when <binary varbinary tinyblob blob mediumblob longblob>.any { 'Blob' }
        when <datetime timestamp>.any { 'DateTime' }
        when 'date' { 'Date' }
        when 'json' { 'Json' }
        when <bool boolean>.any { 'Bool' }
        default { die "Unsupported MySQL column type: $type" }
    }
}


multi method map-exception(X::DBDish::DBError $x where { .code == 1062 }) {
    my $key = $x.native-message ~~ / "for key '" $<key>=( <-[']>+ ) "'" /;
    X::Red::Driver::Mapped::Unique.new:
        :driver<MySQL>,
        :orig-exception($x),
        :fields($key ?? [$key<key>.Str] !! [])
}

multi method map-exception(X::DBDish::DBError $x where { .code == 1050 }) {
    my $table = $x.native-message ~~ / "Table '" $<table>=( <-[']>+ ) "' already exists" /;
    X::Red::Driver::Mapped::TableExists.new:
        :driver<MySQL>,
        :orig-exception($x),
        :table($table ?? $table<table>.Str !! "")
}

=begin pod

=head1 Red::Driver::MySQL

Red driver for MySQL.

=head2 Install

=code zef install Red::Driver::MySQL

=head2 Synopsis

=begin code :lang<raku>
use Red:api<2>;

model Person {...}

model Post is rw {
    has Int         $.id        is serial;
    has Int         $!author-id is referencing( *.id, :model(Person) );
    has Str         $.title     is column{ :unique };
    has Str         $.body      is column;
    has Person      $.author    is relationship{ .author-id };
    has Bool        $.deleted   is column = False;
    has DateTime    $.created   is column .= now;
    has Set         $.tags      is column{
        :type<string>,
        :deflate{ .keys.join: "," },
        :inflate{ set(.split: ",") }
    } = set();
    method delete { $!deleted = True; self.^save }
}

model Person is rw {
    has Int  $.id    is serial;
    has Str  $.name  is column;
    has Post @.posts is relationship{ .author-id };
    method active-posts { @!posts.grep: not *.deleted }
}
my $*RED-DEBUG-RESPONSE = True;
my $*RED-DB = database "MySQL",
    :user<root>,
    :host<127.0.0.1>,
    :password<test>,
    :database<test>,
;
my $*RED-DEBUG = True;
schema(Person, Post).drop.create;

say Post.^create:
    :title<test>,
    :body("test 001"),
    :tags(set <bla ble bli>),
    :author{ :name<fernando> },
;

.say for Person.^all;
.say for Post.^all;
=end code

=head2 Parameters

=item C<Str  :$user>
=item C<Str  :$host>
=item C<Str  :$password>
=item C<Str  :$database>
=item C<UInt :$port>

=head2 Tests

Run the driver tests and the pinned upstream Red suite against MySQL 8.4:

=begin code
docker compose up --build --abort-on-container-exit --exit-code-from tests
docker compose down --volumes
=end code

Each test file gets a separate disposable database. The same command runs on
GitHub Actions for pushes and pull requests. tools/red-revision pins the Red
revision for the build and runner, and TEST_JOBS controls parallelism (default: 4).

For an existing disposable MySQL server and a separate Red checkout:

=begin code
MYSQL_HOST=127.0.0.1 MYSQL_PASSWORD=test RED_SOURCE=/path/to/Red sh tools/test.sh
=end code

The test user needs CREATE DATABASE and DROP DATABASE privileges. The runner
applies tools/red-suite-mysql.patch to the test checkout: it replaces a raw
SQLite/PostgreSQL VALUES fixture with portable SELECT statements and compares
an unordered query as a Bag. Existing upstream skips and TODOs remain intact.

Offline driver tests can run without MySQL:

=begin code
raku -Ilib t/01-basic.t
raku -Ilib t/03-schema-reader.t
raku t/05-runner.t
=end code

=head2 Author

Fernando Correa de Oliveira <fernandocorrea@gmail.com>

=head2 Copyright and license

Copyright 2018 Fernando Correa de Oliveira

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod
