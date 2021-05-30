# Red::Driver::MySQL

Red driver for MySQL.

# Install

```bash
zef install Red::Driver::MySQL
```

# Synopsis

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
    has Int  $.id            is serial;
    has Str  $.name          is column;
    has Post @.posts         is relationship{ .author-id };
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
Person.^create-table;
Post.^create-table;

say Post.^create:
    :title<test>,
    :body("test 001"),
    :tags(set <bla ble bli>),
    :author{ :name<fernando> },
;

.say for Person.^all
```

# Parameters

* Str :$user
* Str :$host
* Str :$password
* Str :$database

# Author

Fernando Correa de Oliveira <fernandocorrea@gmail.com>

# Copyright and license

Copyright 2018 Fernando Correa de Oliveira

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.
