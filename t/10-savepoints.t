use Test;
use Red::Driver::MySQL;
use Red::AST::Savepoint;
use Red::AST::RollbackToSavepoint;
use Red::AST::ReleaseSavepoint;

my $driver = Red::Driver::MySQL.CREATE;
my $*RED-DB = $driver;
my Str $name = 'select"; ` --';
for Red::AST::Savepoint => 'SAVEPOINT',
    Red::AST::RollbackToSavepoint => 'ROLLBACK TO SAVEPOINT',
    Red::AST::ReleaseSavepoint => 'RELEASE SAVEPOINT' -> $operation {
    my $sql = $driver.translate($operation.key.new(:$name));
    is $sql.key, $operation.value ~ ' `select"; `` --`',
        'Savepoint identifier is quoted without treating its contents as SQL';
    is-deeply $sql.value, [], 'Savepoint names are not parameters';
}
subtest 'dry run does not prepare or execute savepoint commands', {
    my $*RED-DRY-RUN = True;
    for <savepoint rollback-to-savepoint release-savepoint> -> $method {
        ok $driver."$method"($name) === $driver, "$method returns the unconnected driver";
    }
};
done-testing;
