import 'package:brick_build/src/offline_first/offline_first_checker.dart';
import 'package:brick_build/src/sqlite_schema/migration_generator.dart';
import 'package:brick_build/src/sqlite_serdes/sqlite_fields.dart';
import 'package:source_gen/source_gen.dart' show LibraryReader;
import 'package:dart_style/dart_style.dart' as dart_style;
import 'package:brick_sqlite_abstract/db.dart'
    show MigrationManager, Schema, SchemaTable, SchemaColumn, InsertForeignKey, InsertTable;
import 'package:source_gen/source_gen.dart';

final _formatter = dart_style.DartFormatter();
const migrationGenerator = MigrationGenerator();

/// Produces a [Schema] from all @[OfflineFirst] annotations
class SqliteSchemaGenerator {
  const SqliteSchemaGenerator();

  /// Complete schema file output
  ///
  /// [classes] are all classes by their table name with the @[OfflineFirst] annotation
  String generate(LibraryReader library, List<SqliteFields> fieldses) {
    final newSchema = _createNewSchema(library, fieldses);
    final existingMigrations = migrationGenerator.expandAllMigrations(library);

    final parts = existingMigrations.map((m) => "part '${m.version}.migration.dart';");
    final migrationClasses = existingMigrations.map((m) => "Migration${m.version}()");

    final output = """
      // GENERATED CODE DO NOT EDIT
      // This file should be version controlled
      import 'package:brick_sqlite_abstract/db.dart';
      // ignore: unused_import
      import 'package:brick_sqlite_abstract/db.dart' show Migratable;
      ${parts.join("\n")}

      /// All intelligently-generated migrations from all `@Migratable` classes on disk
      final Set<Migration> migrations = Set.from([ ${migrationClasses.join(",\n")} ]);

      /// A consumable database structure including the latest generated migration.
      final schema = ${newSchema.forGenerator};
    """;
    return _formatter.format(output);
  }

  /// Produce a migration from the difference between existing migrations and the latest schema
  String createMigration(LibraryReader library, List<SqliteFields> fieldses, {int version}) {
    final newSchema = _createNewSchema(library, fieldses, version: version);

    return migrationGenerator.generate(
      library,
      null,
      newSchema: newSchema,
      version: version,
    );
  }

  /// Create a schema from the contents of all annotated models.
  /// The schema version is incremented from the largest version of all annotated migrations.
  Schema _createNewSchema(LibraryReader library, List<SqliteFields> fieldses, {int version}) {
    final tables = fieldses.fold<Set<SchemaTable>>(Set<SchemaTable>(), (acc, fields) {
      acc.add(_createTable(fields.element.name, fields));
      return acc;
    });

    final existingMigrations = migrationGenerator.expandAllMigrations(library);
    version ??= MigrationManager.latestMigrationVersion(existingMigrations);

    return Schema(version, tables: tables);
  }

  SchemaTable _createTable(String tableName, SqliteFields fields) {
    final columns = _createColumns(fields).where((c) => c != null).toList();
    columns.insert(
      0,
      SchemaColumn(
        InsertTable.PRIMARY_KEY_COLUMN,
        int,
        autoincrement: true,
        isPrimaryKey: true,
        nullable: false,
      ),
    );
    return SchemaTable(tableName, columns: Set.from(columns));
  }

  Iterable<SchemaColumn> _createColumns(SqliteFields fields) {
    return fields.stableInstanceFields.map((field) {
      OfflineFirstChecker checker = OfflineFirstChecker(field.type);
      final column = fields.finder.annotationForField(field);
      final columnName = column.name;
      if (checker.isFuture) {
        checker = OfflineFirstChecker(checker.argType);
      }

      if (column.ignore || !checker.isSerializable) {
        return null;
      }

      if (checker.isDartCoreType) {
        return SchemaColumn(
          columnName,
          checker.asPrimitive,
          nullable: column?.nullable,
          unique: column?.unique,
        );
      } else if (checker.isEnum) {
        return SchemaColumn(
          columnName,
          int,
          nullable: column?.nullable,
          unique: column?.unique,
        );
      } else if (checker.isSibling) {
        return SchemaColumn(
          InsertForeignKey.foreignKeyColumnName(checker.unFuturedType.name, column.name),
          int,
          isForeignKey: true,
          foreignTableName: checker.unFuturedType.name,
          nullable: column?.nullable,
        );
      } else if (checker.hasSerdes) {
        final sqliteType = checker.superClassTypeArgs.last;
        final sqliteChecker = OfflineFirstChecker(sqliteType);
        return SchemaColumn(
          columnName,
          sqliteChecker.asPrimitive,
          nullable: column?.nullable,
          unique: column?.unique,
        );
      } else if (checker.isMap || checker.isIterable) {
        // Iterables and Maps are stored as JSON
        return SchemaColumn(
          columnName,
          String,
          nullable: column?.nullable,
          unique: column?.unique,
        );
      }

      return null;
    });
  }
}
