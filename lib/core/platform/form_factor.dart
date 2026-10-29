import 'dart:io';

import 'package:flutter/foundation.dart';

/// Phones and tablets: touch-first layouts, and lighter rendering for
/// their GPUs.
abstract final class FormFactor {
  static bool get touch => _touch;

  @visibleForTesting
  static set touch(bool value) => _touch = value;

  static bool _touch = Platform.isAndroid || Platform.isIOS;
}
