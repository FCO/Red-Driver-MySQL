[![Build Status](https://travis-ci.org/FCO/Red-Driver-MySQL.svg?branch=master)](https://travis-ci.org/FCO/Red-Driver-MySQL)

### method schema-reader

```raku
method schema-reader() returns Mu
```

NYI

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

NYI

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

Author
------

Fernando Correa de Oliveira <fernandocorrea@gmail.com>

Copyright and license
---------------------

Copyright 2018 Fernando Correa de Oliveira

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

