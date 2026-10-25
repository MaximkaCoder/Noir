import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Points every path_provider directory into one folder, so NOIR can run
/// with a separate, empty profile (demos, screenshots, testing) without
/// touching the real one. Enabled with `--dart-define=NOIR_PROFILE_DIR=…`.
class ProfilePathProvider extends PathProviderPlatform {
  ProfilePathProvider(this.root);

  final String root;

  String _dir(String name) => p.join(root, name);

  @override
  Future<String?> getApplicationSupportPath() async => _dir('support');

  @override
  Future<String?> getApplicationDocumentsPath() async => _dir('documents');

  @override
  Future<String?> getApplicationCachePath() async => _dir('cache');

  @override
  Future<String?> getTemporaryPath() async => _dir('temp');

  @override
  Future<String?> getDownloadsPath() async => _dir('downloads');
}
