/// Defensive navigation through InnerTube JSON, whose shape changes often.
/// Every helper returns null (or an empty list) instead of throwing when a
/// key is missing or a value has an unexpected type.
library;

/// Follows [path] (map keys and list indices) from [json]. Returns null as
/// soon as a step does not fit.
Object? nav(Object? json, List<Object> path) {
  var node = json;
  for (final step in path) {
    if (step is String && node is Map) {
      node = node[step];
    } else if (step is int && node is List) {
      if (step < 0 || step >= node.length) return null;
      node = node[step];
    } else {
      return null;
    }
  }
  return node;
}

Map<String, Object?>? navMap(Object? json, [List<Object> path = const []]) {
  final node = nav(json, path);
  return node is Map ? node.cast<String, Object?>() : null;
}

List<Object?> navList(Object? json, [List<Object> path = const []]) {
  final node = nav(json, path);
  return node is List ? node.cast<Object?>() : const [];
}

String? navString(Object? json, [List<Object> path = const []]) {
  final node = nav(json, path);
  return node is String ? node : null;
}

/// Unwraps `{someRenderer: {...}}` into the renderer name and its body.
/// Returns null when [json] is not a single-key wrapper map.
(String, Map<String, Object?>)? renderer(Object? json) {
  if (json is! Map || json.isEmpty) return null;
  final entry = json.entries.first;
  final body = entry.value;
  if (entry.key is! String || body is! Map) return null;
  return (entry.key as String, body.cast<String, Object?>());
}

/// The text of a `{runs: [...]}` or `{simpleText: ...}` object.
String? textOf(Object? json) {
  final simple = navString(json, ['simpleText']);
  if (simple != null) return simple;
  final runs = navList(json, ['runs']);
  if (runs.isEmpty) return null;
  return runs.map((r) => navString(r, ['text']) ?? '').join();
}

/// First continuation token found in a `continuations` list
/// (`nextContinuationData`, `nextRadioContinuationData`, ...).
String? continuationToken(Object? continuations) {
  for (final c in navList(continuations)) {
    final data = renderer(c)?.$2;
    final token = navString(data, ['continuation']);
    if (token != null && token.isNotEmpty) return token;
  }
  return null;
}

/// Token of a trailing `continuationItemRenderer` (the newer pagination
/// style), if [items] ends with one.
String? continuationItemToken(List<Object?> items) {
  if (items.isEmpty) return null;
  return navString(items.last, [
    'continuationItemRenderer',
    'continuationEndpoint',
    'continuationCommand',
    'token',
  ]);
}
