use X::Red::Exceptions;
use Red::Driver::CommonSQL;
unit role Red::Driver::MySQL::Support does Red::Driver::CommonSQL;

method database-client(--> Hash) {
    my %parameters = self.^attributes.map({ .name.substr(2) => .get_value(self) }).Hash;
    my @command = 'mysql';
    my %environment;
    for <host port user database> -> $parameter {
        @command.push("--$parameter=" ~ %parameters{$parameter})
            if %parameters{$parameter}.defined;
    }
    %environment<MYSQL_PWD> = %parameters<password>.Str if %parameters<password>.defined;
    %(command => @command.Array, environment => %environment.Hash)
}

method create-database(Str:D $name) {
    self.administration-execute('CREATE DATABASE ' ~ self.table-name-wrapper($name));
    True
}

method administration-password(Str:D $password --> Str:D) {
    X::Red::Administration.new(:reason('Passwords cannot contain NUL')).throw
        if $password.contains("\0");
    my $mode = self.execute('SELECT @@SESSION.sql_mode AS mode').row<mode> // '';
    my $value = $mode.split(',').first(* eq 'NO_BACKSLASH_ESCAPES').defined
        ?? $password !! $password.subst("\\", "\\\\", :g);
    "'" ~ $value.subst("'", "''", :g) ~ "'"
}

method create-user(Str:D $name, Str :$password!, Str :$host = '%') {
    self.administration-execute('CREATE USER ' ~ self.table-name-wrapper($name)
        ~ '@' ~ self.table-name-wrapper($host)
        ~ ' IDENTIFIED BY ' ~ self.administration-password($password));
    True
}

method create-role(Str:D $name, Str :$host = '%') {
    self.administration-execute('CREATE ROLE ' ~ self.table-name-wrapper($name)
        ~ '@' ~ self.table-name-wrapper($host));
    True
}

# CREATE ROLE needs DBIish's text-protocol fallback on MySQL.
method administration-execute(Str:D $sql) {
    CATCH { default { self.map-exception($_).throw } }
    self.dbh.execute($sql)
}
