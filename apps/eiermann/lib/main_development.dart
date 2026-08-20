import 'package:eiermann/app/app.dart';
import 'package:eiermann/bootstrap.dart';

Future<void> main() async {
  await bootstrap(() => const App());
}
