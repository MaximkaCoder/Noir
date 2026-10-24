import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/core/database/app_database.dart';

/// Overridden in `bootstrap.dart` (real file) and in tests (in-memory).
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider must be overridden'),
);
