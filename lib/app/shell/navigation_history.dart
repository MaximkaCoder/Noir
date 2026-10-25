import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/router.dart';

/// One visited screen: its location and the `extra` some routes need
/// (albums and artists).
typedef HistoryEntry = ({String location, Object? extra});

final navigationHistoryProvider = Provider<NavigationHistory>((ref) {
  final history = NavigationHistory(ref.watch(routerProvider));
  ref.onDispose(history.dispose);
  return history;
});

/// Browser-like back / forward across every screen, including tab
/// switches: Home → Library → a playlist → Search walks back the same way.
///
/// Records each location the router settles on inside the shell. Now
/// Playing, the queue sheet and dialogs are not history: [back] closes them
/// first, as the system back button does.
class NavigationHistory extends ChangeNotifier {
  NavigationHistory(this._router) {
    _router.routerDelegate.addListener(_record);
    _record();
  }

  static const _limit = 100;

  final GoRouter _router;
  final _back = <HistoryEntry>[];
  final _forward = <HistoryEntry>[];
  HistoryEntry? _current;

  bool get canGoBack => _back.isNotEmpty;
  bool get canGoForward => _forward.isNotEmpty;

  @override
  void dispose() {
    _router.routerDelegate.removeListener(_record);
    super.dispose();
  }

  void _record() {
    final config = _router.routerDelegate.currentConfiguration;
    // Routes above the shell (Now Playing, the queue sheet) close instead.
    if (config.isEmpty || config.matches.last is! ShellRouteMatch) return;
    final entry = (location: config.uri.toString(), extra: config.extra);
    // Also our own [back] / [forward] landing.
    if (entry == _current) return;
    if (_current case final current?) {
      _back.add(current);
      if (_back.length > _limit) _back.removeAt(0);
    }
    _forward.clear();
    _current = entry;
    notifyListeners();
  }

  /// Closes an open dialog, menu or Now Playing; otherwise returns to the
  /// previous screen.
  Future<void> back() async {
    if (await _closeOverlay()) return;
    if (_back.isEmpty) return;
    _forward.add(_current!);
    _go(_back.removeLast());
  }

  /// Returns to the screen [back] left. Does nothing while a dialog or Now
  /// Playing is open.
  void forward() {
    if (_forward.isEmpty || _overlayNavigator() != null) return;
    _back.add(_current!);
    _go(_forward.removeLast());
  }

  void _go(HistoryEntry entry) {
    _current = entry;
    notifyListeners();
    _router.go(entry.location, extra: entry.extra);
  }

  Future<bool> _closeOverlay() async {
    final navigator = _overlayNavigator();
    if (navigator == null) return false;
    // A route that refuses to close keeps the user where they are.
    await navigator.maybePop();
    return true;
  }

  /// The navigator showing something above the current page: the root one
  /// for Now Playing and dialogs, the section's for a route without a page
  /// (a menu pushed onto it).
  NavigatorState? _overlayNavigator() {
    final root = _router.routerDelegate.navigatorKey.currentState;
    final shell = _router.routerDelegate.currentConfiguration.matches
        .whereType<ShellRouteMatch>()
        .firstOrNull;
    final section = shell?.navigatorKey.currentState;
    if (root == null || section == null) return null;
    if (!(ModalRoute.of(section.context)?.isCurrent ?? true)) return root;
    final top = _topRoute(section);
    return top == null || top.settings is Page ? null : section;
  }

  static Route<dynamic>? _topRoute(NavigatorState navigator) {
    Route<dynamic>? top;
    // Stops at once: only reads the top route.
    navigator.popUntil((route) {
      top = route;
      return true;
    });
    return top;
  }
}
