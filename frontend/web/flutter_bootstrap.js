{{flutter_js}}
{{flutter_build_config}}

(async function () {
  // Fetch the Google Maps API key and load Maps JS BEFORE Flutter initialises.
  // After loading, we set window._flutterMapsReady which map_screen.dart polls.
  //
  // URL priority:
  //   1. http://127.0.0.1:8000/api/maps-key  — flutter run dev server (different port)
  //   2. /api/maps-key                        — production (Flutter served from FastAPI)

  window._flutterMapsReady = false;

  async function _fetchMapsKey() {
    const candidates = [
      'http://127.0.0.1:8000/api/maps-key',
      '/api/maps-key',
    ];
    for (const url of candidates) {
      try {
        const r = await fetch(url);
        if (!r.ok) continue;
        const d = await r.json();
        if (d && d.key) return d.key;
      } catch (_) { /* try next */ }
    }
    return null;
  }

  try {
    const key = await _fetchMapsKey();
    if (key) {
      await new Promise(function (resolve) {
        var s     = document.createElement('script');
        s.src     = 'https://maps.googleapis.com/maps/api/js?key='
                    + key + '&libraries=geometry,places';
        s.onload  = function () {
          window._flutterMapsReady = true;   // signal Dart that Maps JS is ready
          resolve();
        };
        s.onerror = function () {
          window._flutterMapsReady = false;  // signal failure — Flutter shows fallback
          resolve();
        };
        document.head.appendChild(s);
      });
    }
  } catch (_) { window._flutterMapsReady = false; }

  // Start Flutter only AFTER Maps JS outcome is known
  _flutter.loader.load();
})();
