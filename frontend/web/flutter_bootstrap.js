{{flutter_js}}
{{flutter_build_config}}

(async function () {
  window._flutterMapsReady = false;

  // Embedded fallback key — used when backend is unreachable (e.g. Firebase hosting without backend)
  var MAPS_KEY = 'AIzaSyDKpurz7K0hw0LD1IQILU-5WwfalMyVM2c';

  async function _fetchWithTimeout(url, ms) {
    var controller = new AbortController();
    var tid = setTimeout(function () { controller.abort(); }, ms);
    try {
      var r = await fetch(url, { signal: controller.signal });
      clearTimeout(tid);
      return r;
    } catch (e) {
      clearTimeout(tid);
      throw e;
    }
  }

  async function _fetchMapsKey() {
    // Candidates in priority order — each has a 3 s timeout
    var candidates = [
      'http://127.0.0.1:8000/api/maps-key',   // local dev
      '/api/maps-key',                          // if served directly from FastAPI
    ];
    for (var i = 0; i < candidates.length; i++) {
      try {
        var r = await _fetchWithTimeout(candidates[i], 3000);
        if (!r.ok) continue;
        var d = await r.json();
        if (d && d.key) return d.key;
      } catch (_) { /* try next */ }
    }
    return null;  // fall through to embedded key
  }

  try {
    var fetched = await _fetchMapsKey();
    if (fetched) MAPS_KEY = fetched;
  } catch (_) {}

  // Load Maps JS with whichever key we have
  await new Promise(function (resolve) {
    var s    = document.createElement('script');
    s.src    = 'https://maps.googleapis.com/maps/api/js?key=' + MAPS_KEY + '&libraries=geometry,places';
    s.onload = function () {
      window._flutterMapsReady = true;
      resolve();
    };
    s.onerror = function () {
      window._flutterMapsReady = false;
      resolve();
    };
    document.head.appendChild(s);
  });

  _flutter.loader.load();
})();
