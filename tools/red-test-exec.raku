#!/usr/bin/env raku
use DBIish;

# prove6 invokes this once per file: each process owns a separate database.
sub MAIN(Str $test) {
    my $root = $?FILE.IO.parent.parent;
    my $red = (%*ENV<RED_SOURCE> // '/red').IO.absolute;
    my %connection =
        host => %*ENV<MYSQL_HOST> // '127.0.0.1',
        port => (%*ENV<MYSQL_PORT> // 3306).Int,
        user => %*ENV<MYSQL_USER> // 'root',
        password => %*ENV<MYSQL_PASSWORD> // 'red-driver-test',
    ;
    my $admin = DBIish.connect('mysql', |%connection);
    my $database = "red_mysql_test_{$*PID}_{now.Int}_{(1000000000.rand.Int)}";
    $admin.execute("CREATE DATABASE `$database`");
    my $status;
    {
        LEAVE {
            $admin.execute("DROP DATABASE `$database`");
            $admin.dispose;
        }
        temp %*ENV<RED_DATABASE> = 'MySQL ' ~
            (|%connection.sort.map({ .key ~ '=' ~ .value }), "database=$database").join(' ');
        my $process = run $*EXECUTABLE, "-I{$root.add('lib')}", "-I$red/lib",
            $test.IO.absolute, :cwd($red);
        $status = $process.exitcode;
    }
    exit $status;
}
