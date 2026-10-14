use Test;
use Red::Driver::MySQL;

my $reader = Red::Driver::MySQL.CREATE.schema-reader;
my $sql = q:to/SQL/;
    CREATE TABLE `person` (
        `id` bigint unsigned NOT NULL AUTO_INCREMENT,
        `name` varchar(40) DEFAULT 'NOT NULL, PRIMARY KEY',
        `balance` decimal(10,2) NOT NULL,
        PRIMARY KEY (`id`),
        UNIQUE KEY `person_name` (`name`)
    ) ENGINE=InnoDB;
    CREATE TABLE `post` (
        `id` int NOT NULL,
        `author_id` bigint unsigned NOT NULL,
        `title` varchar(40) NOT NULL,
        `status` enum('draft','published') DEFAULT 'draft',
        PRIMARY KEY (`id`, `author_id`),
        UNIQUE KEY `author_title` (`author_id`, `title`),
        KEY `title_index` (`title`(10)),
        CONSTRAINT `author_fk` FOREIGN KEY (`author_id`) REFERENCES `person` (`id`)
    ) ENGINE=InnoDB
    SQL
my @tables = $reader.table-definition-from-create-table($sql);
is @tables.elems, 2, 'parse multiple CREATE TABLE statements';
is @tables[0].name, 'person', 'quoted table name';
ok @tables[0].columns[0].pk, 'table primary key applied to column';
nok @tables[0].columns[0].nullable, 'primary key is not nullable';
ok @tables[0].columns[1].nullable, 'keywords in default strings are ignored';
ok @tables[0].columns[1].unique, 'single column unique index';
is @tables[0].columns[2].type, 'decimal(10,2)', 'precision and scale retained';
ok @tables[1].columns[0].pk && @tables[1].columns[1].pk, 'composite primary key';
nok @tables[1].columns[1].unique || @tables[1].columns[2].unique,
    'composite unique index does not imply individual uniqueness';
is-deeply @tables[1].columns[1].references, %(table => 'person', column => 'id'),
    'foreign key reference';
is @tables[1].columns[3].perl-type, 'Str', 'enum type';
nok $reader.table-definition-from-create-table(Any).exists, 'missing table';
dies-ok { $reader.table-definition-from-create-table('invalid SQL') }, 'invalid SQL rejected';
done-testing;
