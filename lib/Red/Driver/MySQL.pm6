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
use X::Red::Exceptions;
use UUID;
use Red::SchemaReader;
#use Red::Driver::MySQL::SchemaReader;
use Red::Type::Json;
unit class Red::Driver::MySQL does Red::Driver::CommonSQL;

has Str                       $!user;
has Str                       $!password;
has Str                       $!host;
has Int                       $!port;
has Str                       $!database;
has DBDish::mysql::Connection $.dbh;

#| NYI
method schema-reader { } #Red::Driver::MySQL::SchemaReader }

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
}

class Statement does Red::Statement {
    method stt-exec($stt, *@bind) {
        $.driver.debug: (@bind || @!binds);
        $stt.execute:  |(@bind || @!binds);
        $stt
    }
    method stt-row($stt) { $stt.row: :hash }
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

#multi method join-type("outer") { die "'OUTER JOIN' is not supported by MySQL" }
#multi method join-type("right") { die "'RIGHT JOIN' is not supported by MySQL" }

# TODO: do not hardcode it
#| Begin transaction
#| it's being overrided here because MySQL do not accept BEGIN on `prepare`
method begin {
    my $trans = self.new-connection;
    my $sql = "BEGIN";
    self.debug: $sql;
    $trans.dbh.execute: $sql;
    $trans
}

#| Table name wrapper
method table-name-wrapper($name) { qq[`$name`] }

multi method should-drop-cascade { True }

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

#| NYI
multi method translate(Red::AST::Insert $_ where { !.values.grep({ .value.value.defined }) }, $context?) {
    die "Insert empty row on MySQL is NYI"
}

multi method translate(Red::AST::Value $_ where .type ~~ Bool, $context? where $_ ne "bind") {
    (.value ?? 1 !! 0) => []
}

multi method translate(Red::AST::Value $_ where { .type ~~ Json }, $context? where { !.defined || $_ ne "bind" }) {
    self.translate:
            Red::AST::Function.new(:func<JSON>, :args[ ast-value .value, :type(Str) ]),
            $context
}

multi method translate(Red::AST::Not $_ where { .value ~~ Red::Column and .value.attr.type !~~ Str }, $context?) {
    my ($val, @bind) := do given self.translate: .value, $context { .key, .value }
    "($val == 0 OR $val IS NULL)" => @bind
}

multi method translate(Red::AST::So $_ where { .value ~~ Red::Column and .value.attr.type !~~ Str }, $context?) {
    my ($val, @bind) := do given self.translate: .value, $context { .key, .value }
    "($val <> 0 AND $val IS NOT NULL)" => @bind
}

multi method translate(Red::AST::Not $_ where { .value ~~ Red::Column and .value.attr.type ~~ Str }, $context?) {
    my ($val, @bind) := do given self.translate: .value, $context { .key, .value }
    "($val == '' OR $val IS NULL)" => @bind
}

multi method translate(Red::AST::So $_ where { .value ~~ Red::Column and .value.attr.type ~~ Str }, $context?) {
    my ($val, @bind) := do given self.translate: .value, $context { .key, .value }
    "($val <> '' AND $val IS NOT NULL)" => @bind
}

multi method translate(Red::AST::RowId $_, $context?) { "ROWID" => [] }

multi method translate(Red::AST::LastInsertedRow $_, $context?) {
    my $of     = .of;
    my $filter = $of.^id-filter: Red::AST::Function.new: :func<LAST_INSERT_ID>;
    self.translate(Red::AST::Select.new: :$of, :table-list[$of], :$filter, :1limit)
}

multi method translate(Red::Column $_, "column-auto-increment") { (.auto-increment ?? "AUTO_INCREMENT" !! "") => [] }

multi method translate(Red::Column $_, "column-comment") {
    (" { self.comment-starter } $_\n" with .comment) => []
}

multi method translate(Red::AST::TableComment $_, $context?) {
        (" { self.comment-starter } { .msg }" => []) with $_
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

#multi method default-type-for(Red::Column $ where .attr.type ~~ Mu             --> Str:D) {"varchar(255)"}
multi method default-type-for(Red::Column $ where .attr.type ~~ Bool            --> Str:D) {"integer"}
multi method default-type-for(Red::Column $ where .attr.type ~~ one(Int, Bool)  --> Str:D) {"integer"}
multi method default-type-for(Red::Column $ where .attr.type ~~ UUID            --> Str:D) {"varchar(36)"}
multi method default-type-for(Red::Column $ where .attr.type ~~ Json            --> Str:D) {"json"}
#multi method default-type-for(Red::Column $ where .attr.type ~~ Any             --> Str:D) {"varchar(255)"}
multi method default-type-for(Red::Column $                                     --> Str:D) {"varchar(255)"}
multi method default-type-for($ --> Str:D) is default {"varchar(255)"}


multi method map-exception(X::DBDish::DBError $x where { (.?code == 19 or .?code == 1555 or .?code == 2067) and .native-message.starts-with: "UNIQUE constraint failed:" }) {
    X::Red::Driver::Mapped::Unique.new:
        :driver<MySQL>,
        :orig-exception($x),
        :fields($x.native-message.substr(26).split: /\s* "," \s*/)
}

multi method map-exception(X::DBDish::DBError $x where { .?code == 1 and .native-message ~~ m:i/^table \s+ $<table>=(\w+) \s+ already \s+ exists/ }) {
    X::Red::Driver::Mapped::TableExists.new:
            :driver<MySQL>,
            :orig-exception($x),
            :table($<table>.Str)
}

multi method map-exception(X::DBDish::DBError $x where { .?code == 1 and .native-message ~~ m:i/^table \s+ \"$<table>=(\w+)\" \s+ already \s+ exists/ }) {
    X::Red::Driver::Mapped::TableExists.new:
            :driver<MySQL>,
            :orig-exception($x),
            :table($<table>.Str)
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

=head2 Author

Fernando Correa de Oliveira <fernandocorrea@gmail.com>

=head2 Copyright and license

Copyright 2018 Fernando Correa de Oliveira

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod
