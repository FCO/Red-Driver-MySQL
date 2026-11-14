use Red::Driver::MySQL::Support;

unit role Red::Driver::MySQL::Migrations does Red::Driver::MySQL::Support;

method migration-nontransactional-ddl(--> Bool:D) { True }
method migration-auto-column($column, Str $table --> List:D) {
    ($column.type, ' PRIMARY KEY AUTO_INCREMENT')
}
method migration-alter-column(Str $table, $before, $column, Str $definition --> Array:D) {
    ['ALTER TABLE ' ~ self.table-name-wrapper($table) ~ ' MODIFY COLUMN ' ~ $definition]
}
method migration-drop-index(Str $table, Str $index --> Str:D) {
    'DROP INDEX ' ~ self.table-name-wrapper($index) ~ ' ON ' ~ self.table-name-wrapper($table)
}
method migration-lock(Bool :$read-only = False) {
    my $statement = self.execute("SELECT GET_LOCK(CONCAT('red_migrations:', SHA1(DATABASE())), 0) AS acquired");
    LEAVE $statement.finish-transaction if $statement.defined;
    self.migration-error('Another migration executor holds the database lock')
        unless $statement.row<acquired>.Str.lc eq any(<1 true t>);
}
method migration-unlock {
    my $statement = self.execute("SELECT RELEASE_LOCK(CONCAT('red_migrations:', SHA1(DATABASE())))");
    $statement.finish-transaction;
}
method migration-validate-column($table, $before, $column) {
    return unless $before.normalized-type ne $column.normalized-type
        || $before.nullable != $column.nullable;
    my $statement = self.execute(q:to/SQL/, $table.name, $column.name);
        SELECT c.COLUMN_DEFAULT AS column_default, c.EXTRA AS extra,
               c.COLUMN_COMMENT AS comment, c.COLLATION_NAME AS collation_name,
               t.TABLE_COLLATION AS table_collation
        FROM information_schema.COLUMNS c
        JOIN information_schema.TABLES t
          ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
        WHERE c.TABLE_SCHEMA = DATABASE() AND c.TABLE_NAME = ? AND c.COLUMN_NAME = ?
        SQL
    LEAVE $statement.finish-transaction if $statement.defined;
    my $row = $statement.row;
    self.migration-error("MySQL alteration would lose unmanaged metadata: {$table.name}.{$column.name}")
        if !$row || $row<column_default>.defined || ($row<extra> // '').Str.chars
            || ($row<comment> // '').Str.chars
            || ($row<collation_name>.defined && $row<collation_name> ne $row<table_collation>);
}

method migration-finish-unexecuted(--> Bool:D) { True }
method migration-sql-options(--> Hash:D) {
    %(hash-comment => True, dash-comment-whitespace => True,
        reject-hint-comment => True, dollar-quotes => False)
}
method migration-string-literal(Str $value --> Str:D) {
    my $hex = $value.encode('utf8').map(*.fmt('%02x')).join;
    "CONVERT(X'$hex' USING utf8mb4)"
}
method migration-provision(IO::Path $folder, Str $name, %server --> Hash:D) {
    self.migration-error('Configure a test server for MySQL') unless %server;
    my %parameters = %server;
    %parameters<database> //= 'mysql';
    my $admin = self.new(|%parameters);
    $admin.execute('CREATE DATABASE ' ~ $admin.table-name-wrapper($name));
    %parameters<database> = $name;
    %(parameters => %parameters, :$admin, created => True)
}
method migration-drop-temporary($admin, Str $name) {
    $admin.execute('DROP DATABASE ' ~ $admin.table-name-wrapper($name));
}
