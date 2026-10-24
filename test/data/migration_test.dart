import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/app_database.dart';

import '../generated_migrations/schema.dart';

/// Guards the on-disk schema. When bumping `schemaVersion`:
///   dart run drift_dev schema dump lib/core/database/app_database.dart drift_schemas/
///   dart run drift_dev schema generate drift_schemas/ test/generated_migrations/
/// then add a `migrateAndValidate` case from the previous version.
void main() {
  late SchemaVerifier verifier;

  setUpAll(() => verifier = SchemaVerifier(GeneratedHelper()));

  test('current schema matches the v1 snapshot', () async {
    final connection = await verifier.startAt(1);
    final db = AppDatabase(connection);
    await verifier.migrateAndValidate(db, 1);
    await db.close();
  });
}
