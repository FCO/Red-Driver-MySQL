use Test;
use Red::Driver::MySQL::Support;

use Red::Driver::SQLite;

class Settings does Red::Driver::MySQL::Support {
    multi method prepare(Str $sql) { die 'SQL is unavailable in this settings test' }
    method schema-reader { die 'Schema is unavailable in this settings test' }
    has Str $!host = 'db.example';
    has Int $!port = 3307;
    has Str $!user = 'reader';
    has Str $!password = 'secret';
    has Str $!database = 'project';
}
my $settings = Settings.bless;
my %client = $settings.database-client;
is-deeply %client<command>,
    ['mysql', '--host=db.example', '--port=3307', '--user=reader', '--database=project'],
    'native client arguments';
is %client<environment><MYSQL_PWD>, 'secret', 'password stays outside arguments';
done-testing;
