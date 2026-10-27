import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/shared/models/media.dart';

/// Extra header controls for a page of songs, contributed by optional
/// modules; [page] identifies it (`youtube:<playlist id>`,
/// `ytm:<browse id>`).
typedef CollectionExtras = List<Widget> Function(
  String page,
  List<Track> tracks,
);

/// None by default.
final collectionExtrasProvider = Provider<CollectionExtras>(
  (ref) =>
      (_, _) => const [],
);
