import 'dart:js_interop';

// flutter_bootstrap.js sets window._flutterMapsReady = true after Maps JS onload
@JS('_flutterMapsReady')
external JSBoolean? get _flutterMapsReady;

bool isMapsJsLoaded() {
  try {
    final v = _flutterMapsReady;
    return v != null && v.toDart;
  } catch (_) {
    return false;
  }
}
