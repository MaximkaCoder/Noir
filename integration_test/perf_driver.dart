// Host side for running the perf test in profile mode:
//
//   flutter drive --driver=integration_test/perf_driver.dart \
//     --target=integration_test/now_playing_perf_test.dart -d windows --profile
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
