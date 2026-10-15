[![Build Status](https://travis-ci.org/FCO/Red-Driver-MySQL.svg?branch=master)](https://travis-ci.org/FCO/Red-Driver-MySQL)

### method schema-reader

```raku
method schema-reader() returns Mu
```

Read tables, columns and indexes from the connected database.

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

Tests
-----

Run the driver tests and the pinned upstream Red suite against MySQL 8.4:

    docker compose up --build --abort-on-container-exit --exit-code-from tests
    docker compose down --volumes

Each test file gets a separate disposable database. The same command runs on GitHub Actions for pushes and pull requests with `RAKUDO_RAKUAST=0`. tools/red-revision pins Red to `d01165685356cc06ec2e00e57ef561b857699af2` for the build and runner, including the JSON operations, projection chains, and SQL tail regression suites. TEST_JOBS controls parallelism (default: 4).

For an existing disposable MySQL server and a separate Red checkout:

    MYSQL_HOST=127.0.0.1 MYSQL_PASSWORD=test RED_SOURCE=/path/to/Red sh tools/test.sh

The test user needs CREATE DATABASE and DROP DATABASE privileges. The pinned Red revision includes the portable view fixtures and unordered-result comparison upstream, so the runner uses the checkout without applying patches. Existing upstream skips and TODOs remain intact.

Offline driver tests can run without MySQL:

    raku -Ilib t/01-basic.t
    raku -Ilib t/03-schema-reader.t
    raku t/05-runner.t
    RAKUDO_RAKUAST=0 raku -Ilib -I/path/to/Red/lib t/06-query-translation.t

The translation tests require the pinned Red API. `t/07-query-mysql.t` covers offsets, projected JSON operations, and bound text across pagination and tail boundaries. Text results reported by MySQL using BLOB-family types are decoded only when their result metadata specifies a nonbinary charset; actual binary BLOB columns remain byte buffers.

Author
------

Fernando Correa de Oliveira <fernandocorrea@gmail.com>

Copyright and license
---------------------

Copyright 2018 Fernando Correa de Oliveira

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

