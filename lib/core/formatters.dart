/// `3:07`, `1:02:45`.
String formatClock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// `2h 14m`, `47m`, `< 1m`.
String formatTotal(Duration d) {
  if (d.inMinutes < 1) return '< 1m';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  return h > 0 ? '${h}h ${m}m' : '${m}m';
}

/// `1 song`, `32 songs`.
String songCount(int n) => n == 1 ? '1 song' : '$n songs';

/// Time-of-day greeting for Home.
String greetingFor(DateTime now) => switch (now.hour) {
  >= 5 && < 12 => 'Good morning,',
  >= 12 && < 18 => 'Good afternoon,',
  _ => 'Good evening,',
};
