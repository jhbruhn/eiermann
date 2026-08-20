import 'package:eiermann/app/app.dart';
import 'package:eiermann/bootstrap.dart';

// A bare `flutter run` with no --dart-define-from-file lands here, and
// AppEnvironment then defaults to the development flavor. Kept so the app
// starts for somebody who just cloned the repo; the flavored entrypoints
// (main_development.dart and friends) are what CI and the release build use.
Future<void> main() async {
  await bootstrap(() => const App());
}
