use Red::SchemaReader;
use Red::Cli::Table;
use Red::Cli::Column;

unit class Red::Driver::MySQL::SchemaReader does Red::SchemaReader;

has $.driver is required;

# Keep quoted strings and nested expressions intact when splitting definitions.
grammar CreateTable {
    token TOP { ^ \s* <table>+ % [ ';' \s* ] ';'? \s* $ }
    rule table {
        :i CREATE [ TEMPORARY ]? TABLE [ IF NOT EXISTS ]?
        <name=qualified> '(' <definition>+ % ',' ')' <options>
    }
    token quoted {
        | "'" [ "''" | '\\' . | <-[']> ]* "'"
        | '"' [ '""' | '\\' . | <-["]> ]* '"'
        | '`' [ '``' | <-[`]> ]* '`'
    }
    token identifier { '`' [ '``' | <-[`]> ]+ '`' | <[\w\$]>+ }
    rule qualified { <identifier>+ % '.' }
    token group { '(' [ <quoted> | <group> | <-[()'"`]> ]* ')' }
    token definition { [ <quoted> | <group> | <-[(),'"`]> ]+ }
    token options { [ <quoted> | <-[;'"`]> ]* }
}

grammar Definition is CreateTable {
    token TOP { ^ \s* [ <primary> || <unique> || <foreign> || <index> || <check> || <column> ] \s* $ }
    rule constraint { :i CONSTRAINT <identifier> }
    rule key-list { '(' <key-column>+ % ',' ')' }
    rule key-column { <identifier> <group>? [ :i ASC | DESC ]? }
    rule primary { :i <constraint>? PRIMARY KEY [ USING \w+ ]? <key-list> <tail> }
    rule unique { :i <constraint>? UNIQUE [ KEY | INDEX ]? <identifier>? [ USING \w+ ]? <key-list> <tail> }
    rule foreign { :i <constraint>? FOREIGN KEY <identifier>? <local=key-list> REFERENCES <target=qualified> <remote=key-list> <tail> }
    rule index { :i [ FULLTEXT | SPATIAL ]? [ KEY | INDEX ] <tail> }
    rule check { :i <constraint>? CHECK <tail> }
    rule column { <name=identifier> <type> <tail> }
    rule type { :i \w+ [ PRECISION | VARYING ]? <group>? [ UNSIGNED ]? [ ZEROFILL ]? }
    token tail { .* }
}

sub unquote(Str $name) {
    $name.starts-with('`') ?? $name.substr(1, $name.chars - 2).subst('``', '`', :g) !! $name
}

sub key-columns($match) {
    $match<key-column>.map({ unquote .<identifier>.Str }).Array
}

method !rows(Str $sql, *@bind) {
    my $statement = $!driver.execute: $sql, |@bind;
    gather while $statement.row -> $row {
        # MySQL exposes some textual metadata (notably COLUMN_TYPE) as BLOBs.
        take $row.map({ .key => (.value ~~ Blob ?? .value.decode('utf8') !! .value) }).Hash;
    }
}

method tables-names {
    self!rows(q:to/SQL/).map(*.<name>)
        SELECT TABLE_NAME AS name FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE'
        ORDER BY TABLE_NAME
        SQL
}

# Each index has its ordered columns; composite unique indexes are kept intact.
method indexes-of(Str:D $table) {
    my @rows = self!rows(q:to/SQL/, $table);
        SELECT INDEX_NAME AS name, COLUMN_NAME AS column_name,
               NON_UNIQUE AS non_unique, INDEX_TYPE AS type
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?
        ORDER BY INDEX_NAME, SEQ_IN_INDEX
        SQL
    my @indexes;
    for @rows -> %row {
        if !@indexes || @indexes.tail<name> ne %row<name> {
            @indexes.push: %(
                name => %row<name>,
                unique => !%row<non_unique>,
                primary => %row<name> eq 'PRIMARY',
                type => %row<type>,
                columns => [],
            );
        }
        @indexes.tail<columns>.push: %row<column_name>;
    }
    @indexes
}

method table-definition(Str:D $table) {
    my @columns = self!rows(q:to/SQL/, $table);
        SELECT COLUMN_NAME AS name, COLUMN_TYPE AS column_type, IS_NULLABLE AS nullable
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?
        ORDER BY ORDINAL_POSITION
        SQL
    return Red::Cli::Table.new(:name($table), :!exists) unless @columns;
    my @indexes = self.indexes-of($table);
    my %references;
    for self!rows(q:to/SQL/, $table) -> %row {
        SELECT COLUMN_NAME AS name, REFERENCED_TABLE_NAME AS referenced_table,
               REFERENCED_COLUMN_NAME AS referenced_column
        FROM information_schema.KEY_COLUMN_USAGE
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?
          AND REFERENCED_TABLE_NAME IS NOT NULL
        SQL
        %references{%row<name>} = %(
            table => %row<referenced_table>, column => %row<referenced_column>,
        );
    }
    Red::Cli::Table.new(:name($table), :columns(@columns.map(-> %row {
        my @keys = @indexes.grep({ .<columns>.first(* eq %row<name>).defined });
        Red::Cli::Column.new:
            :name(%row<name>), :type(%row<column_type>),
            :perl-type($!driver.type-for-sql(%row<column_type>)),
            :nullable(%row<nullable> eq 'YES'),
            :pk(so @keys.first(*.<primary>)),
            :unique(so @keys.first({ .<unique> && .<columns>.elems == 1 && !.<primary> })),
            :references(%references{%row<name>} // Any);
    }).Array))
}

multi method table-definition-from-create-table(Any:U) { Red::Cli::Table.new(:!exists) }

multi method table-definition-from-create-table(Str:D $sql) {
    my $parsed = CreateTable.parse($sql);
    die 'Invalid MySQL CREATE TABLE statement' unless $parsed;
    do for $parsed<table> -> $table {
        my @columns;
        my %columns;
        my @constraints;
        for $table<definition> -> $definition {
            my $parsed-definition = Definition.parse($definition.Str.trim);
            die "Unsupported MySQL table definition: $definition" unless $parsed-definition;
            if $parsed-definition<column> -> $column {
                my $name = unquote $column<name>.Str;
                # A comment/default string containing 'NOT NULL' is not a modifier.
                my $tail = $column<tail>.Str.subst(/<CreateTable::quoted>/, '', :g);
                my %data =
                    :$name,
                    :type($column<type>.Str.trim.lc),
                    :nullable(!so $tail ~~ /:i 'NOT' \s+ 'NULL' | 'PRIMARY' \s+ 'KEY'/),
                    :pk(so $tail ~~ /:i 'PRIMARY' \s+ 'KEY'/),
                    :unique(so $tail ~~ /:i 'UNIQUE'/),
                    :references(%()),
                ;
                @columns.push: %data;
                %columns{$name} := @columns.tail;
            } else {
                @constraints.push: $parsed-definition;
            }
        }
        for @constraints -> $constraint {
            if $constraint<primary> -> $primary {
                for key-columns($primary<key-list>) -> $name {
                    %columns{$name}<pk> = True;
                    %columns{$name}<nullable> = False;
                }
            }
            if $constraint<unique> -> $unique {
                my @names = key-columns($unique<key-list>);
                %columns{@names.head}<unique> = True if @names == 1;
            }
            if $constraint<foreign> -> $foreign {
                my @local = key-columns($foreign<local>);
                my @remote = key-columns($foreign<remote>);
                die 'Mismatched MySQL foreign key columns' unless @local == @remote;
                for @local Z @remote -> ($local, $remote) {
                    %columns{$local}<references> = %(
                        table => unquote($foreign<target><identifier>.tail.Str),
                        column => $remote,
                    );
                }
            }
        }
        Red::Cli::Table.new:
            :name(unquote $table<name><identifier>.tail.Str),
            :columns(@columns.map({
                Red::Cli::Column.new: |$_,
                    :references(.<references>.elems ?? .<references> !! Any),
                    :perl-type($!driver.type-for-sql(.<type>))
            }).Array),
    }
}
