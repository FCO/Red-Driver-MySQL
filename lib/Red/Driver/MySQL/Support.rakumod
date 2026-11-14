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
