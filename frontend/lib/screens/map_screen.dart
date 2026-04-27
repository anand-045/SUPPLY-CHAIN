import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../utils/maps_ready_stub.dart'
    if (dart.library.js_interop) '../utils/maps_ready_web.dart';

// ── Colour palette ────────────────────────────────────────────────────────────
const Color _kPrimary  = Color(0xFF0A1628);
const Color _kCard     = Color(0xFF0F2040);
const Color _kSurface  = Color(0xFF142848);
const Color _kAccent   = Color(0xFF00D4AA);
const Color _kCritical = Color(0xFFFF4757);
const Color _kWarning  = Color(0xFFFFB300);

// ─────────────────────────────────────────────────────────────────────────────
// MapScreen
// ─────────────────────────────────────────────────────────────────────────────
class MapScreen extends StatefulWidget {
  final Map<String, dynamic> routeData;
  final String shipmentId;
  final String routeLabel;

  const MapScreen({
    super.key,
    required this.routeData,
    required this.shipmentId,
    required this.routeLabel,
  });

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController?      _ctrl;
  Set<Polyline>             _polylines   = {};
  Set<Marker>               _markers     = {};
  int                       _selectedIdx = 0;

  // ── Map loading / error state ──────────────────────────────────────────────
  bool _mapsLoaded = false;   // true once Maps JS is confirmed ready (or absent)
  bool _mapsError  = false;   // true if Maps JS unavailable
  int  _mapsChecks = 0;       // poll counter (max 50 × 100 ms = 5 s timeout)

  // ── Platform support: google_maps_flutter works on Android / iOS / Web ─────
  static bool get _mapSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _initMapData();   // direct assignment — runs before first build
    _initMaps();      // platform/web detection — direct assignment where sync
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  // ── Maps initialisation ────────────────────────────────────────────────────
  void _initMaps() {
    if (!_mapSupported) {
      _mapsLoaded = true;
      _mapsError  = true;
      debugPrint('[MapScreen] Platform unsupported — showing fallback');
      return;
    }

    if (!kIsWeb) {
      // Native Android / iOS: SDK is always ready at this point
      _mapsLoaded = true;
      return;
    }

    // Web: flutter_bootstrap.js sets window._flutterMapsReady = true/false
    // after the Maps JS script tag resolves. Poll until the flag is set or
    // until 5 s have elapsed (50 × 100 ms), then render or show fallback.
    _pollMapsJs();
  }

  void _pollMapsJs() {
    if (!mounted) return;

    if (isMapsJsLoaded()) {
      debugPrint('[MapScreen] Maps JS ready — rendering GoogleMap');
      setState(() { _mapsLoaded = true; _mapsError = false; });
      return;
    }

    _mapsChecks++;

    if (_mapsChecks >= 50) {
      // 5 s timeout — Maps JS is not available
      debugPrint('[MapScreen] Maps JS not ready after 5 s — showing fallback');
      setState(() { _mapsLoaded = true; _mapsError = true; });
      return;
    }

    Future.delayed(const Duration(milliseconds: 100), _pollMapsJs);
  }

  // ── Decode Google-encoded polyline → LatLng list ───────────────────────────
  List<LatLng> _decodePolyline(String? encoded) {
    if (encoded == null || encoded.isEmpty) return const [];
    final List<LatLng> pts = [];
    int index = 0, lat = 0, lng = 0;
    final len = encoded.length;
    try {
      while (index < len) {
        int b, shift = 0, result = 0;
        do {
          b = encoded.codeUnitAt(index++) - 63;
          result |= (b & 0x1F) << shift;
          shift += 5;
        } while (b >= 0x20);
        lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
        shift = 0; result = 0;
        do {
          b = encoded.codeUnitAt(index++) - 63;
          result |= (b & 0x1F) << shift;
          shift += 5;
        } while (b >= 0x20);
        lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
        pts.add(LatLng(lat / 1e5, lng / 1e5));
      }
    } catch (_) {}
    return pts;
  }

  // ── Build polyline + marker sets (called from initState — no setState) ─────
  void _initMapData() {
    final data    = widget.routeData;
    final routes  = (data['routes'] as List?) ?? [];
    final bestIdx = (data['best_route_index'] as int?) ?? 0;
    final oLat    = (data['origin_lat'] as num?)?.toDouble() ?? 0.0;
    final oLon    = (data['origin_lon'] as num?)?.toDouble() ?? 0.0;
    final dLat    = (data['dest_lat']   as num?)?.toDouble() ?? 0.0;
    final dLon    = (data['dest_lon']   as num?)?.toDouble() ?? 0.0;

    debugPrint('[MapScreen] routes.length = ${routes.length}  '
        'bestIdx=$bestIdx  origin=($oLat,$oLon)  dest=($dLat,$dLon)');

    if (routes.isEmpty) {
      debugPrint('[MapScreen] No route data — will show fallback');
      return;
    }

    _selectedIdx = bestIdx.clamp(0, routes.length - 1);
    final polys   = <Polyline>{};
    final markers = <Marker>{};

    for (int i = 0; i < routes.length; i++) {
      final r      = routes[i] as Map;
      final isBest = i == bestIdx;

      // ── Resolve polyline points ──────────────────────────────────────────
      List<LatLng> pts = [];
      final coordsList = r['polyline_coords'] as List?;

      if (coordsList != null && coordsList.isNotEmpty) {
        pts = coordsList.map((c) {
          final lat = (c['lat'] as num?)?.toDouble() ?? 0.0;
          final lng = (c['lng'] as num?)?.toDouble() ?? 0.0;
          return LatLng(lat, lng);
        }).toList();
      }

      if (pts.isEmpty) {
        final enc = r['encoded_polyline'] as String?;
        debugPrint('[MapScreen] Route $i: encoded_polyline '
            '${enc != null && enc.isNotEmpty ? "present (${enc.length} chars)" : "absent"}');
        pts = _decodePolyline(enc);
      }

      // Straight-line fallback if no geometry from API
      if (pts.isEmpty && oLat != 0) {
        debugPrint('[MapScreen] Route $i: no geometry — using straight-line fallback');
        pts = [LatLng(oLat, oLon), LatLng(dLat, dLon)];
      }

      if (pts.isNotEmpty) {
        polys.add(Polyline(
          polylineId: PolylineId('route_$i'),
          points:     pts,
          color:  isBest
              ? const Color(0xFF00D4AA)
              : Colors.white.withValues(alpha: 0.25),
          width:  isBest ? 5 : 3,
          zIndex: isBest ? 2 : 1,
          patterns: isBest
              ? const []
              : [PatternItem.dash(18), PatternItem.gap(10)],
        ));
      }
    }

    final parts = (data['route'] as String? ?? '').split(' → ');
    if (oLat != 0) {
      markers.add(Marker(
        markerId:   const MarkerId('origin'),
        position:   LatLng(oLat, oLon),
        icon:       BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: InfoWindow(
          title:   'Origin',
          snippet: parts.isNotEmpty ? parts.first : '',
        ),
      ));
    }
    if (dLat != 0) {
      markers.add(Marker(
        markerId:   const MarkerId('destination'),
        position:   LatLng(dLat, dLon),
        icon:       BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: InfoWindow(
          title:   'Destination',
          snippet: parts.length > 1 ? parts.last : '',
        ),
      ));
    }

    // Direct assignment — initState runs before first build, no setState needed
    _polylines = polys;
    _markers   = markers;
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _fitBounds(oLat, oLon, dLat, dLon));
  }

  void _fitBounds(double oLat, double oLon, double dLat, double dLon) {
    if (_ctrl == null || oLat == 0 || dLat == 0) return;
    _ctrl!.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(math.min(oLat, dLat) - 0.8, math.min(oLon, dLon) - 0.8),
        northeast: LatLng(math.max(oLat, dLat) + 0.8, math.max(oLon, dLon) + 0.8),
      ),
      56,
    ));
  }

  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final data     = widget.routeData;
    final routes   = (data['routes'] as List?) ?? [];
    final bestIdx  = (data['best_route_index'] as int?) ?? 0;
    final savings  = (data['savings']  as Map?) ?? {};
    final currency = (savings['currency'] as String?) ?? 'USD';

    final showMap = _mapsLoaded && !_mapsError && _mapSupported && routes.isNotEmpty;

    return Scaffold(
      backgroundColor: _kPrimary,
      appBar: AppBar(
        backgroundColor: _kPrimary,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.shipmentId,
              style: const TextStyle(
                  color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
          Text(widget.routeLabel,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45), fontSize: 11)),
        ]),
        actions: [
          if (routes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Center(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _kAccent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _kAccent.withValues(alpha: 0.3)),
                ),
                child: Text('${routes.length} route${routes.length == 1 ? '' : 's'}',
                    style: const TextStyle(color: _kAccent, fontSize: 11)),
              )),
            ),
        ],
      ),
      body: Column(children: [

        // ── Map area (flex 3) ────────────────────────────────────────────────
        Expanded(
          flex: 3,
          child: _buildMapArea(data, showMap),
        ),

        // ── Analytics panel ──────────────────────────────────────────────────
        Container(
          decoration: const BoxDecoration(
            color: _kPrimary,
            border: Border(top: BorderSide(color: Color(0xFF1E3A5F), width: 1)),
          ),
          child: routes.isEmpty
              ? _buildNoDataMessage()
              : Column(children: [

                  // Savings chips
                  if (savings['distance_km'] != null ||
                      savings['delay_avoided_min'] != null ||
                      savings['time_min']    != null ||
                      savings['cost']        != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                      child: Row(children: [
                        _savingChip(Icons.straighten_rounded,
                            '${savings['distance_km'] ?? 0} km', 'dist saved'),
                        const SizedBox(width: 8),
                        _savingChip(Icons.timer_outlined,
                            '${savings['delay_avoided_min'] ?? savings['time_min'] ?? 0} min',
                            'delay avoided'),
                        const SizedBox(width: 8),
                        _savingChip(
                            savings['co2_saved_kg'] != null
                                ? Icons.eco_rounded
                                : Icons.savings_outlined,
                            savings['co2_saved_kg'] != null
                                ? '${savings['co2_saved_kg']} kg CO₂'
                                : '$currency ${_fmt(savings['cost'])}',
                            savings['co2_saved_kg'] != null ? 'CO₂ saved' : 'cost saved'),
                      ]),
                    ),

                  const SizedBox(height: 10),

                  // Route selector chips
                  if (routes.length > 1)
                    SizedBox(
                      height: 44,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        itemCount: routes.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (_, i) {
                          final r        = routes[i] as Map;
                          final isBest   = i == bestIdx;
                          final selected = i == _selectedIdx;
                          return GestureDetector(
                            onTap: () => setState(() => _selectedIdx = i),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 160),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: selected
                                    ? _kAccent.withValues(alpha: 0.18)
                                    : _kCard,
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(
                                  color: selected
                                      ? _kAccent
                                      : Colors.white.withValues(alpha: 0.1),
                                ),
                              ),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                if (isBest) ...[
                                  const Icon(Icons.star_rounded,
                                      color: _kAccent, size: 13),
                                  const SizedBox(width: 4),
                                ],
                                Text(
                                  'Route ${i + 1}  '
                                  '${r['distance_km'] ?? '?'} km  '
                                  '${_fmt(r['duration_min'])} min'
                                  '${(r['synthetic'] == true) ? "  (est.)" : ""}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: selected
                                        ? _kAccent
                                        : Colors.white.withValues(alpha: 0.55),
                                    fontWeight: selected
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                              ]),
                            ),
                          );
                        },
                      ),
                    ),

                  const SizedBox(height: 10),

                  if (_selectedIdx >= 0 && _selectedIdx < routes.length)
                    _buildRouteCard(routes[_selectedIdx] as Map, bestIdx, currency),

                  const SizedBox(height: 10),
                ]),
        ),
      ]),
    );
  }

  // ── Map area widget — loading / error / live map ───────────────────────────
  Widget _buildMapArea(Map data, bool showMap) {
    final routes = (data['routes'] as List?) ?? [];

    if (!_mapsLoaded) {
      return Container(
        color: _kSurface,
        child: Center(child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(
                color: _kAccent, strokeWidth: 2),
            const SizedBox(height: 16),
            Text('Loading map…',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4), fontSize: 13)),
          ],
        )),
      );
    }

    if (!showMap || routes.isEmpty) {
      return _buildMapFallback(data);
    }

    final oLat = (data['origin_lat'] as num?)?.toDouble() ?? 0.0;
    final oLon = (data['origin_lon'] as num?)?.toDouble() ?? 0.0;

    return GoogleMap(
      initialCameraPosition: CameraPosition(
        target: LatLng(oLat, oLon),
        zoom: 5,
      ),
      polylines:               _polylines,
      markers:                 _markers,
      mapType:                 MapType.normal,
      myLocationButtonEnabled: false,
      zoomControlsEnabled:     true,
      onMapCreated: (ctrl) {
        debugPrint('[MapScreen] GoogleMap created successfully');
        _ctrl = ctrl;
        final dLat = (data['dest_lat'] as num?)?.toDouble() ?? 0.0;
        final dLon = (data['dest_lon'] as num?)?.toDouble() ?? 0.0;
        _fitBounds(oLat, oLon, dLat, dLon);
      },
    );
  }

  // ── No route data message ─────────────────────────────────────────────────
  Widget _buildNoDataMessage() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(child: Column(children: [
        Icon(Icons.route_outlined,
            color: Colors.white.withValues(alpha: 0.2), size: 40),
        const SizedBox(height: 12),
        Text('No route data available',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5), fontSize: 14)),
        const SizedBox(height: 6),
        Text('Upload a CSV and run the analysis to generate routes.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.25), fontSize: 11)),
      ])),
    );
  }

  // ── Fallback — Windows / missing Maps JS / no data ─────────────────────────
  Widget _buildMapFallback(Map data) {
    final routes  = (data['routes'] as List?) ?? [];
    final bestIdx = (data['best_route_index'] as int?) ?? 0;
    final parts   = (data['route'] as String? ?? '').split(' → ');

    return Container(
      color: _kSurface,
      child: Column(children: [

        Expanded(child: Center(child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (routes.isEmpty)
              Icon(Icons.map_outlined,
                  color: Colors.white.withValues(alpha: 0.15), size: 52)
            else ...[
              _routeDot(Colors.greenAccent,
                  parts.isNotEmpty ? parts.first : 'Origin'),
              ...List.generate(4, (_) => Container(
                  width: 2, height: 10,
                  color: Colors.white.withValues(alpha: 0.12))),
              _routeDot(_kAccent,
                  parts.length > 1 ? parts.last : 'Destination'),
            ],
            const SizedBox(height: 20),
            Text(
              routes.isEmpty
                  ? 'No route data'
                  : '${routes.length} route${routes.length == 1 ? '' : 's'} calculated',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45), fontSize: 14),
            ),
            const SizedBox(height: 6),
            Text(
              _mapsError
                  ? 'Map unavailable — set GOOGLE_MAPS_API_KEY and restart backend'
                  : !_mapSupported
                      ? 'Map not supported on this platform'
                      : 'Route analytics below',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.2), fontSize: 11),
            ),
          ],
        ))),

        if (routes.isNotEmpty)
          SizedBox(
            height: 160,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              itemCount: routes.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final r      = routes[i] as Map;
                final isBest = i == bestIdx;
                return Container(
                  width: 185,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _kCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isBest
                          ? _kAccent.withValues(alpha: 0.4)
                          : Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Row(children: [
                      if (isBest) ...[
                        const Icon(Icons.star_rounded,
                            color: _kAccent, size: 12),
                        const SizedBox(width: 4),
                      ],
                      Expanded(child: Text(
                        'Route ${i + 1}'
                        '${(r['synthetic'] == true) ? " (est.)" : ""}',
                        style: TextStyle(
                          color: isBest ? _kAccent : Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      )),
                    ]),
                    const SizedBox(height: 6),
                    _stat('${r['distance_km'] ?? '?'} km',     'distance'),
                    _stat('${_fmt(r['duration_min'])} min',     'duration'),
                    _stat(_fmt(r['risk_adjusted_score']),       'risk score'),
                  ]),
                );
              },
            ),
          ),
      ]),
    );
  }

  // ── Route detail card (analytics panel) ───────────────────────────────────
  Widget _buildRouteCard(Map r, int bestIdx, String currency) {
    final isRec  = (r['index'] as int?) == bestIdx;
    final risk   = (r['risk_score'] as num?)?.toDouble() ?? 0;
    final riskColor = risk > 60 ? _kCritical : risk > 30 ? _kWarning : _kAccent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isRec
                ? _kAccent.withValues(alpha: 0.35)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Row(children: [
              if (isRec) ...[
                const Icon(Icons.verified_rounded, color: _kAccent, size: 14),
                const SizedBox(width: 4),
              ],
              Text(
                isRec ? 'Best Route' : 'Route ${((r['index'] as int?) ?? 0) + 1}',
                style: TextStyle(
                  color: isRec ? _kAccent : Colors.white,
                  fontSize: 13, fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: riskColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Risk ${risk.toStringAsFixed(0)}'
                  '${(r['synthetic'] == true) ? " est." : ""}',
                  style: TextStyle(
                      fontSize: 9,
                      color: riskColor,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 18, runSpacing: 4, children: [
              _stat('${r['distance_km'] ?? '?'} km',         'distance'),
              _stat('${_fmt(r['duration_min'])} min',         'duration'),
              if (r['effective_time_min'] != null)
                _stat('${_fmt(r['effective_time_min'])} min', 'ETA (w/ delay)'),
              if (r['expected_delay_hr'] != null)
                _stat(
                    '${(r['expected_delay_hr'] as num).toStringAsFixed(1)} hr',
                    'exp. delay'),
              _stat('$currency ${_fmt(r['total_cost'])}',     'base cost'),
              _stat('$currency ${_fmt(r['fuel_cost'])}',      'fuel'),
              _stat('$currency ${_fmt(r['toll_cost'])}',      'tolls'),
              _stat('$currency ${_fmt(r['driver_cost'])}',    'driver'),
              if (r['co2_kg'] != null)
                _stat('${r['co2_kg']} kg', 'CO₂'),
            ]),
            if ((r['traffic_penalty'] as int? ?? 0) > 0 ||
                (r['weather_penalty'] as int? ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(spacing: 18, children: [
                  _stat(
                      '$currency ${_fmt(r['traffic_penalty'])}', 'traffic pen.'),
                  _stat(
                      '$currency ${_fmt(r['weather_penalty'])}', 'weather pen.'),
                ]),
              ),
            if (r['why_this_route'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  r['why_this_route'] as String,
                  style: TextStyle(
                      fontSize: 10,
                      color: Colors.white.withValues(alpha: 0.45),
                      height: 1.4),
                ),
              ),
          ])),

          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (r['efficiency_score'] != null) ...[
              Text('Efficiency',
                  style: TextStyle(
                      fontSize: 9,
                      color: Colors.white.withValues(alpha: 0.35))),
              Text(
                '${r['efficiency_score']}',
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: _kAccent),
              ),
              Text('/ 100',
                  style: TextStyle(
                      fontSize: 9,
                      color: Colors.white.withValues(alpha: 0.3))),
            ] else ...[
              Text('Score',
                  style: TextStyle(
                      fontSize: 9,
                      color: Colors.white.withValues(alpha: 0.35))),
              Text(
                _fmt(r['risk_adjusted_score']),
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: _kAccent),
              ),
              Text('risk-adj.',
                  style: TextStyle(
                      fontSize: 9,
                      color: Colors.white.withValues(alpha: 0.3))),
            ],
          ]),
        ]),
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  Widget _routeDot(Color color, String label) {
    return Column(children: [
      Container(
        width: 14, height: 14,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(height: 4),
      Text(label,
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6), fontSize: 11)),
    ]);
  }

  Widget _savingChip(IconData icon, String value, String label) {
    return Expanded(child: Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kAccent.withValues(alpha: 0.2)),
      ),
      child: Row(children: [
        Icon(icon, color: _kAccent, size: 14),
        const SizedBox(width: 6),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
          Text(label,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.35), fontSize: 9)),
        ])),
      ]),
    ));
  }

  Widget _stat(String value, String label) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value,
          style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
      Text(label,
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35), fontSize: 9)),
    ]);
  }

  String _fmt(dynamic val) {
    if (val == null) return '—';
    final n = val is double
        ? val.toInt()
        : val is int ? val : int.tryParse(val.toString()) ?? 0;
    if (n >= 1_000_000) return '${(n / 1_000_000).toStringAsFixed(1)}M';
    if (n >= 1_000)     return '${(n / 1_000).toStringAsFixed(1)}K';
    return n.toString();
  }
}
