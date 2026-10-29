[![Build Status](https://travis-ci.org/FCO/Red-Driver-MySQL.svg?branch=master)](https://travis-ci.org/FCO/Red-Driver-MySQL)

### method schema-reader

```raku
method schema-reader() returns Mu
```

Read tables, columns and indexes from the connected database.

### method indexes-for-table

```raku
method indexes-for-table(
    Str $table
) returns Array
```

Inspect ordered index keys, including legacy unique constraints and PRIMARY.

### multi method prepare

```raku
multi method prepare(
    Str $query
) returns Mu
```

Prepare statement

### method begin

```raku
method begin() returns Mu
```

Begin transaction it's being overrided here because MySQL do not accept BEGIN on `prepare`

### method table-name-wrapper

```raku
method table-name-wrapper(
    $name
) returns Mu
```

Table name wrapper

### multi method translate

```raku
multi method translate(
    Red::AST::Infix $_ where { ... },
    $context?
) returns Mu
```

TODO Change Red to define the operator translation

### multi method translate

```raku
multi method translate(
    Red::AST::Not $_ where { ... },
    $context?
) returns Mu
```

TODO Change Red to translate AST instead of hardcoded string

### multi method translate

```raku
multi method translate(
    Red::AST::Insert $_ where { ... },
    $context?
) returns Mu
```

MySQL's syntax for inserting a row using only database defaults.

Red::Driver::MySQL
==================

Red driver for MySQL.

Install
-------

    zef install Red::Driver::MySQL

Synopsis
--------

```raku
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
```

Parameters
----------

  * `Str :$user`

  * `Str :$host`

  * `Str :$password`

  * `Str :$database`

  * `UInt :$port`

Savepoints
----------

With a Red checkout providing the savepoint API, nested transactions use MySQL savepoints on the existing connection. Names are quoted as identifiers and commands use the text protocol. Rolling back to a savepoint keeps its marker active; releasing it does not commit the surrounding transaction. Dry runs do not execute the commands.

Declarative indexes
-------------------

With a Red checkout providing Red::Index and Red::AST::CreateIndex, MySQL supports the core's declarative column, composite, functional and unique indexes:

```raku
model Contact {
    has Int $.id is serial;
    has Int $.account-id is indexed<account-email>;
    has Str $.email is indexed('account-email', { .lc });
    has Str $.code is unique;
    has $.email-prefix is index{ .email.substr(0, 2) };
}
Contact.^create-table;
Contact.^create-indexes; # Safe to repeat; also adds declarations to existing tables.
```

The driver preserves the core's SQL names, key order and legacy unique constraints. Catalog inspection uses the current database and a bound table name. Prefix keys, descending keys, invisible indexes and non-BTREE indexes cannot be mistaken for the default complete ascending definitions. Conflicting definitions raise X::Red::Index before pending indexes are created; duplicate existing data still raises X::Red::Driver::Mapped::Unique. No index is silently rebuilt and stored values, collation and NULL semantics are unchanged.

Functional keys require MySQL 8.0.13 or later and follow MySQL's restrictions on functions and result types, including TEXT/BLOB expressions. DDL has no bound parameters. Catalog normalization handles MySQL's literal escaping, utf8mb4 introducers and function spelling while retaining casts, lengths, grouping and explicit collations. It assumes the driver's default utf8mb4 connection charset.

Tests
-----

Run the driver tests and the pinned upstream Red suite against MySQL 8.4:

    docker compose up --build --abort-on-container-exit --exit-code-from tests
    docker compose down --volumes

Each test file gets a separate disposable database. The same command runs on GitHub Actions for pushes and pull requests with Rakudo 2026.09 and RAKUDO_RAKUAST=0. tools/red-revision pins Red to 52e1d1a49cf01ad1afa3310e7654f04c5de4a1d5 for the build and runner, including the JSON operations, projection chains, and SQL tail and declarative index regression suites. TEST_JOBS controls parallelism (default: 4).

For an existing disposable MySQL server and a separate Red checkout:

    MYSQL_HOST=127.0.0.1 MYSQL_PASSWORD=test RED_SOURCE=/path/to/Red sh tools/test.sh

The test user needs CREATE DATABASE and DROP DATABASE privileges. The runner uses the pinned checkout without applying patches: portable view fixtures and the unordered-result comparison are included upstream. Existing upstream skips and TODOs remain intact.

Offline driver tests can run without MySQL:

    raku -Ilib t/01-basic.t
    raku -Ilib t/03-schema-reader.t
    raku t/05-runner.t
    RAKUDO_RAKUAST=0 raku -Ilib -I/path/to/Red/lib t/06-query-translation.t

The translation tests require the pinned Red API. t/07-query-mysql.t covers offsets, projected JSON operations, and bound text across pagination and tail boundaries. Text results reported by MySQL using BLOB-family types are decoded only when their result metadata specifies a nonbinary charset; actual binary BLOB columns remain byte buffers.

To validate new core APIs using a local Red checkout rather than the pinned Docker revision, use Rakudo 2026.09 with a disposable MySQL 8.4 server. Set MYSQL_HOST, MYSQL_PORT, MYSQL_USER and MYSQL_PASSWORD for that server, then run:

    export RED_SOURCE=/path/to/Red RAKUDO_RAKUAST=0
    raku tools/red-test-exec.raku "$RED_SOURCE/t/97-indexes.rakutest"
    prove6 -j 4 -e "raku $PWD/tools/red-test-exec.raku" "$RED_SOURCE/t"
    prove6 -j 4 -e "raku $PWD/tools/red-test-exec.raku" t

The executor adds both checkouts to the module search path and creates one database per file. tools/test.sh retains its exact pinned-revision check; the commands above explicitly select the local core without changing CI pins.

Author
------

Fernando Correa de Oliveira <fernandocorrea@gmail.com>

Copyright and license
---------------------

Copyright 2018 Fernando Correa de Oliveira

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

