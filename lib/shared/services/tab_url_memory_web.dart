import 'package:web/web.dart' as web;

String readUrlFragment() => web.window.location.hash;

void replaceUrlFragment(String fragment) {
  if (web.window.location.hash == fragment) return;
  web.window.history.replaceState(null, '', fragment);
}
