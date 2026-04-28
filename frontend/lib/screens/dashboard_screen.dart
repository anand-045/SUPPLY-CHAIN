import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'map_screen.dart';

// ─────────────────────────────────────────────
// CONSTANTS
// ─────────────────────────────────────────────
String getBaseUrl() {
  // If you want to use the deployed cloud backend:
  return "https://supply-chain-7onq.onrender.com";

  /* // Keep this commented out unless you are running the backend 
  // locally on your laptop right now:
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return "http://10.0.2.2:8000";
  }
  return "http://127.0.0.1:8000";
  */
}

const String kBaseUrl = "http://127.0.0.1:8000";
const Color  kPrimary   = Color(0xFF0A1628);
const Color  kAccent    = Color(0xFF00D4AA);
const Color  kCard      = Color(0xFF0F2040);
const Color  kSurface   = Color(0xFF142848);
const Color  kCritical  = Color(0xFFFF4757);
const Color  kWarning   = Color(0xFFFFB300);
const Color  kSafe      = Color(0xFF00D4AA);

const List<String> kRequiredCsvColumns = [
  "shipment_id", "origin", "destination", "distance_km",
  "cargo_type", "vehicle_type", "status",
];
 
// ─────────────────────────────────────────────
// MAIN APP
// ─────────────────────────────────────────────
void main() => runApp(const SmartSupplyApp());
 
class SmartSupplyApp extends StatelessWidget {
  const SmartSupplyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Supply Chain',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: kPrimary,
        colorScheme: const ColorScheme.dark(
          primary: kAccent,
          surface: kCard,
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}
 
// ─────────────────────────────────────────────
// DASHBOARD SCREEN
// ─────────────────────────────────────────────
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}
 
class _DashboardScreenState extends State<DashboardScreen>
    with TickerProviderStateMixin {
 
  late Dio _dio;
  bool   isLoading  = false;
  String statusMsg  = "";
  int    currentStep = 0;
  int    _tabIndex   = 0;
 
  List shipments = [];
  List alerts    = [];
  Map  summary   = {};

  String _searchQuery = '';
  String _filterFlag  = 'All';
  String _sortMode    = 'risk_desc';
  final TextEditingController _searchCtrl = TextEditingController();
  Map<String, Map> _routeCache   = {};
  Map<String, Map> _predictions  = {};
 
  late AnimationController _pulseCtrl;
  late AnimationController _fadeCtrl;
  late Animation<double>   _fadeAnim;
 
  @override
  void initState() {
    super.initState();
    final baseUrl = getBaseUrl();
    debugPrint('[Network] Base URL: $baseUrl');
    _dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 120),
      sendTimeout: const Duration(seconds: 60),
    ));
    _pulseCtrl = AnimationController(
      vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _fadeCtrl  = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 800));
    _fadeAnim  = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeIn);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkBackendConnection());
  }
 
  @override
  void dispose() {
    _pulseCtrl.dispose();
    _fadeCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }
 
  Color flagColor(String flag) {
    if (flag == "Critical") return kCritical;
    if (flag == "Warning")  return kWarning;
    return kSafe;
  }
 
  IconData flagIcon(String flag) {
    if (flag == "Critical") return Icons.dangerous_rounded;
    if (flag == "Warning")  return Icons.warning_amber_rounded;
    return Icons.check_circle_rounded;
  }

  // ── CSV validation helpers ───────────────────
  List<String> _parseCsvHeaders(Uint8List bytes) {
    final content = utf8.decode(bytes, allowMalformed: true);
    final firstLine = content.split('\n').first.trim();
    final clean = firstLine.startsWith('﻿') ? firstLine.substring(1) : firstLine;
    return clean.split(',').map((h) => h.trim().toLowerCase()).toList();
  }

  List<String>? _validateCsvColumns(Uint8List bytes) {
    final headers = _parseCsvHeaders(bytes);
    final missing = kRequiredCsvColumns.where((col) => !headers.contains(col)).toList();
    return missing.isEmpty ? null : missing;
  }

  int _parseHour(String departureTime) {
    if (departureTime.isEmpty) return 12;
    try {
      return DateTime.parse(departureTime.replaceAll(' ', 'T')).hour;
    } catch (_) {}
    try {
      final timePart = departureTime.split(' ').last;
      return int.parse(timePart.split(':').first);
    } catch (_) {}
    return 12;
  }

  // ── Total cost savings across all optimized routes ──
  double get _totalSavings {
    double savings = 0;
    for (final a in alerts) {
      final orig = (a['original_cost'] as Map?)?['total_cost'];
      final alt  = (a['alt_cost']      as Map?)?['total_cost'];
      if (orig != null && alt != null) {
        final diff = (orig as num).toDouble() - (alt as num).toDouble();
        if (diff > 0) savings += diff;
      }
    }
    return savings;
  }

  String get _savingsCurrency {
    if (alerts.isEmpty) return 'USD';
    return (alerts.first['original_cost'] as Map?)?['currency'] as String? ?? 'USD';
  }

  // ── Computed filtered/sorted shipments ───────
  List get _filteredShipments {
    var result = List.from(shipments);
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      result = result.where((s) =>
        (s['shipment_id'] ?? '').toLowerCase().contains(q) ||
        (s['route']       ?? '').toLowerCase().contains(q) ||
        (s['cargo_type']  ?? '').toLowerCase().contains(q)
      ).toList();
    }
    if (_filterFlag != 'All') {
      result = result.where((s) => s['flag'] == _filterFlag).toList();
    }
    result.sort((a, b) {
      switch (_sortMode) {
        case 'risk_asc':      return (a['risk_score'] ?? 0).compareTo(b['risk_score'] ?? 0);
        case 'distance_desc': return (b['distance_km'] ?? 0).compareTo(a['distance_km'] ?? 0);
        case 'id_asc':        return (a['shipment_id'] ?? '').compareTo(b['shipment_id'] ?? '');
        default:              return (b['risk_score'] ?? 0).compareTo(a['risk_score'] ?? 0);
      }
    });
    return result;
  }

  // ── Error / info dialogs ─────────────────────
  void _showErrorDialog(String title, String message, {bool showRetry = false}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: kCritical.withOpacity(0.4)),
        ),
        title: Row(children: [
          const Icon(Icons.error_rounded, color: kCritical, size: 22),
          const SizedBox(width: 10),
          Expanded(child: Text(title,
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold))),
        ]),
        content: Text(message,
            style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14, height: 1.5)),
        actions: [
          if (showRetry)
            TextButton(
              onPressed: () { Navigator.of(ctx).pop(); runFullAnalysis(); },
              child: const Text("Retry",
                  style: TextStyle(color: kAccent, fontWeight: FontWeight.bold)),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("Dismiss",
                style: TextStyle(color: Colors.white.withOpacity(0.5))),
          ),
        ],
      ),
    );
  }

  void _showColumnErrorDialog(List<String> missingColumns) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: kWarning.withOpacity(0.4)),
        ),
        title: Row(children: [
          const Icon(Icons.table_chart_rounded, color: kWarning, size: 22),
          const SizedBox(width: 10),
          const Text("Invalid CSV Format",
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Missing ${missingColumns.length} required column(s):",
                style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13)),
            const SizedBox(height: 10),
            ...missingColumns.map((col) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                const Icon(Icons.close, color: kCritical, size: 16),
                const SizedBox(width: 8),
                Text(col, style: const TextStyle(
                    color: kCritical, fontSize: 13, fontFamily: 'monospace')),
              ]),
            )),
            const SizedBox(height: 10),
            Text("Required: ${kRequiredCsvColumns.join(', ')}",
                style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.4))),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () { Navigator.of(ctx).pop(); _showSampleCsvDialog(); },
            child: const Text("Download Sample",
                style: TextStyle(color: kAccent, fontWeight: FontWeight.bold)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("OK", style: TextStyle(color: Colors.white.withOpacity(0.5))),
          ),
        ],
      ),
    );
  }

  static const String _sampleCsv =
      "shipment_id,origin,destination,distance_km,cargo_type,vehicle_type,status\n"
      "SHP001,Mumbai,Delhi,1400,electronics,truck,in_transit\n"
      "SHP002,London,Paris,340,medicine,van,pending\n"
      "SHP003,New York,Chicago,1270,food,truck,in_transit\n"
      "SHP004,Tokyo,Shanghai,1765,clothing,truck,delayed\n"
      "SHP005,Dubai,Riyadh,970,electronics,truck,in_transit\n";

  void _showSampleCsvDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          const Icon(Icons.download_rounded, color: kAccent, size: 20),
          const SizedBox(width: 8),
          const Text("Sample CSV Template",
              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
        ]),
        content: SingleChildScrollView(
          child: SelectableText(
            _sampleCsv,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: kAccent),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text("Close", style: TextStyle(color: kAccent)),
          ),
        ],
      ),
    );
  }

  // ── Backend connectivity probe ───────────────
  Future<void> _checkBackendConnection() async {
    final primary   = _dio.options.baseUrl;
    final fallback  = primary.contains('10.0.2.2')
        ? "http://127.0.0.1:8000"
        : "http://10.0.2.2:8000";

    debugPrint('[Network] Probing $primary ...');
    try {
      await Dio(BaseOptions(
        baseUrl: primary,
        connectTimeout: const Duration(seconds: 5),
      )).get("/");
      debugPrint('[Network] $primary reachable');
    } on DioException catch (e) {
      debugPrint('[Network] $primary unreachable (${e.type}) — trying $fallback');
      try {
        await Dio(BaseOptions(
          baseUrl: fallback,
          connectTimeout: const Duration(seconds: 5),
        )).get("/");
        debugPrint('[Network] Fallback $fallback reachable — switching');
        _dio.options.baseUrl = fallback;
      } on DioException {
        debugPrint('[Network] Both URLs unreachable');
        if (mounted) {
          _showErrorDialog(
            "Backend Not Running",
            "Could not reach the server at:\n$primary\n\n"
            "Start the backend with:\nuvicorn Backend.main:app --host 0.0.0.0 --port 8000\n\n"
            "Then tap Retry or restart the app.",
            showRetry: false,
          );
        }
      }
    }
  }

  // ── Run all layers ───────────────────────────
  Future<void> runFullAnalysis() async {
    FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
      withData: true,
    );
    if (picked == null) return;
 
    PlatformFile file = picked.files.single;
    if (file.bytes == null) return;

    final missingCols = _validateCsvColumns(file.bytes!);
    if (missingCols != null) {
      _showColumnErrorDialog(missingCols);
      return;
    }

    setState(() {
      isLoading    = true;
      currentStep  = 0;
      shipments    = [];
      alerts       = [];
      summary      = {};
      statusMsg    = "Initializing analysis pipeline...";
      _searchQuery = '';
      _filterFlag  = 'All';
      _sortMode    = 'risk_desc';
      _routeCache  = {};
      _predictions = {};
    });
    _searchCtrl.clear();
 
    try {
      debugPrint('[Network] POST ${_dio.options.baseUrl}/ingest/upload');
      // Layer 0
      setState(() { statusMsg = "Layer 0 — Ingesting shipment data..."; currentStep = 1; });
      FormData formData = FormData.fromMap({
        "file": MultipartFile.fromBytes(file.bytes!, filename: file.name),
      });
      await _dio.post("/ingest/upload", data: formData);

      // Layer 1
      setState(() { statusMsg = "Layer 1 — Detecting weather disruptions..."; currentStep = 2; });
      await _dio.post("/detect/disruptions");

      // Layer 3
      setState(() { statusMsg = "Layer 3 — Running ML risk model..."; currentStep = 3; });
      final l3 = await _dio.post("/risk/score");

      // Layer 4
      setState(() { statusMsg = "Layer 4 — Generating AI alerts..."; currentStep = 4; });
      final l4 = await _dio.post("/alerts/generate");
 
      final loadedAlerts    = (l4.data['alerts']    as List? ?? []);
      final loadedShipments = (l3.data['shipments'] as List? ?? []);

      setState(() {
        shipments   = loadedShipments;
        alerts      = loadedAlerts;
        summary     = l3.data['summary'] ?? {};
        currentStep = 5;
        statusMsg   = "Layer 5 — Optimizing routes for at-risk shipments...";
      });

      // Layer 5: route optimisation (at-risk) + ML delay prediction (all) — run concurrently
      final atRisk = loadedAlerts
          .where((a) => a['flag'] == 'Critical' || a['flag'] == 'Warning')
          .toList();

      final routeFutures = atRisk.map((alert) async {
        try {
          final res = await _dio.post(
            "/route/optimize",
            queryParameters: {
              "shipment_id": alert['shipment_id'],
              "origin":      alert['origin']      ?? '',
              "destination": alert['destination'] ?? '',
            },
          );
          return MapEntry(alert['shipment_id'] as String, res.data as Map);
        } catch (_) { return null; }
      }).toList();

      final predFutures = loadedShipments.map((s) async {
        try {
          final res = await _dio.post("/predict", data: {
            "distance_km":   s['distance_km'] ?? 500,
            "traffic_level": 0.5,
            "weather":       "clear",
            "cargo_weight":  1000,
            "hour":          _parseHour(s['departure_time']?.toString() ?? ''),
            "cargo_type":    s['cargo_type'] ?? 'general',
          });
          return MapEntry(s['shipment_id'] as String, res.data as Map);
        } catch (_) { return null; }
      }).toList();

      final combined = await Future.wait([
        Future.wait(routeFutures),
        Future.wait(predFutures),
      ]);

      final routeResults = combined[0] as List;
      final predResults  = combined[1] as List;

      final routeCache = <String, Map>{};
      for (final e in routeResults) {
        if (e != null) routeCache[(e as MapEntry).key] = e.value as Map;
      }
      final predCache = <String, Map>{};
      for (final e in predResults) {
        if (e != null) predCache[(e as MapEntry).key] = e.value as Map;
      }

      setState(() {
        _routeCache  = routeCache;
        _predictions = predCache;
        isLoading    = false;
        statusMsg    = "Analysis complete — ${loadedShipments.length} shipments processed, "
                       "${atRisk.length} routes optimized, ${predCache.length} predictions loaded";
        currentStep  = 6;
      });
      _fadeCtrl.forward(from: 0);
 
    } catch (e) {
      setState(() { isLoading = false; statusMsg = ""; });

      String title = "Upload Failed";
      String message;

      if (e is DioException) {
        if (e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.sendTimeout) {
          title = "Connection Timeout";
          message = "Could not reach the server. Make sure the backend is running at ${_dio.options.baseUrl}.";
        } else if (e.type == DioExceptionType.receiveTimeout) {
          title = "Server Timeout";
          message = "The server took too long to respond. Try again in a moment.";
        } else if (e.response?.statusCode == 400) {
          final detail = e.response?.data is Map
              ? e.response!.data['detail'] ?? "Invalid request"
              : e.response?.data?.toString() ?? "Invalid request";
          title = "Validation Error";
          message = "The server rejected the upload:\n\n$detail";
        } else if (e.type == DioExceptionType.connectionError) {
          title = "Server Unreachable";
          message = "Cannot connect to ${_dio.options.baseUrl}.\n\nStart the backend with:\npython Backend/main.py";
        } else {
          message = "A network error occurred. Please try again.";
        }
      } else {
        message = "An unexpected error occurred:\n\n${e.toString()}";
      }

      _showErrorDialog(title, message, showRetry: true);
    }
  }
 
  // ── Open route detail sheet ──────────────────
  void _openRouteSheet(Map alert) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => RouteDetailSheet(
        alert: alert,
        dio: _dio,
        baseUrl: _dio.options.baseUrl,
      ),
    );
  }
 
  // ── Open chatbot sheet ───────────────────────
  void _openChatbot() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => ChatbotSheet(shipments: shipments, alerts: alerts),
    );
  }
 
  // ─────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kPrimary,
      body: Column(children: [
        _buildHeader(),
        Expanded(
          child: shipments.isEmpty && !isLoading
              ? _buildEmptyState()
              : _buildContent(),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openChatbot,
        backgroundColor: kAccent,
        foregroundColor: kPrimary,
        icon: const Icon(Icons.chat_bubble_rounded),
        label: const Text("AI Assistant", style: TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }
 
  // ── Header ───────────────────────────────────
  Widget _buildHeader() {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 12,
        left: 20, right: 20, bottom: 16,
      ),
      decoration: BoxDecoration(
        color: kCard,
        border: Border(bottom: BorderSide(color: kAccent.withOpacity(0.2), width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: kAccent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: kAccent.withOpacity(0.4)),
                  ),
                  child: const Icon(Icons.local_shipping_rounded, color: kAccent, size: 20),
                ),
                const SizedBox(width: 12),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text("Smart Supply Chain",
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                  Text("Real-time Disruption Intelligence",
                      style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.5))),
                ]),
              ]),
              // Upload button
              GestureDetector(
                onTap: isLoading ? null : runFullAnalysis,
                child: AnimatedBuilder(
                  animation: _pulseCtrl,
                  builder: (_, __) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          kAccent.withOpacity(0.8 + _pulseCtrl.value * 0.2),
                          const Color(0xFF00A884),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [BoxShadow(
                        color: kAccent.withOpacity(0.3 + _pulseCtrl.value * 0.2),
                        blurRadius: 12, spreadRadius: 1,
                      )],
                    ),
                    child: Row(children: [
                      isLoading
                          ? const SizedBox(width: 14, height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: kPrimary))
                          : const Icon(Icons.upload_file_rounded, color: kPrimary, size: 16),
                      const SizedBox(width: 8),
                      Text(isLoading ? "Analyzing..." : "Upload CSV",
                          style: const TextStyle(color: kPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                    ]),
                  ),
                ),
              ),
            ],
          ),
 
          // Progress bar while loading
          if (isLoading) ...[
            const SizedBox(height: 12),
            _buildProgressBar(),
          ],
 
          // Status message
          if (statusMsg.isNotEmpty && !isLoading) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: kAccent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kAccent.withOpacity(0.2)),
              ),
              child: Text(statusMsg,
                  style: TextStyle(fontSize: 11, color: kAccent.withOpacity(0.9))),
            ),
          ],
        ],
      ),
    );
  }
 
  Widget _buildProgressBar() {
    final steps = ["Upload", "Weather", "ML Model", "AI Alerts", "Routes", "Done"];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(
        children: List.generate(steps.length, (i) {
          final done    = i < currentStep;
          final active  = i == currentStep - 1;
          return Expanded(child: Row(children: [
            Container(
              width: 20, height: 20,
              decoration: BoxDecoration(
                color: done ? kAccent : (active ? kAccent.withOpacity(0.5) : kSurface),
                shape: BoxShape.circle,
                border: Border.all(color: kAccent.withOpacity(0.4)),
              ),
              child: done
                  ? const Icon(Icons.check, size: 12, color: kPrimary)
                  : active
                      ? const Center(child: SizedBox(width: 10, height: 10,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: kAccent)))
                      : null,
            ),
            if (i < steps.length - 1)
              Expanded(child: Container(height: 1.5,
                  color: done ? kAccent : kSurface)),
          ]));
        }),
      ),
      const SizedBox(height: 4),
      Text(statusMsg,
          style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.5))),
    ]);
  }
 
  // ── Empty state ──────────────────────────────
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 100, height: 100,
            decoration: BoxDecoration(
              color: kAccent.withOpacity(0.1),
              shape: BoxShape.circle,
              border: Border.all(color: kAccent.withOpacity(0.3), width: 2),
            ),
            child: const Icon(Icons.cloud_upload_rounded, size: 50, color: kAccent),
          ),
          const SizedBox(height: 24),
          const Text("Upload Your Shipment Data",
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 8),
          Text("AI-powered real-time disruption detection\nfor global supply chains",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.white.withOpacity(0.5), height: 1.6)),
          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _featureChip(Icons.wb_sunny_rounded, "Live Weather"),
              const SizedBox(width: 12),
              _featureChip(Icons.psychology_rounded, "ML Model"),
              const SizedBox(width: 12),
              _featureChip(Icons.auto_awesome_rounded, "Gemini AI"),
            ],
          ),
          const SizedBox(height: 32),
          GestureDetector(
            onTap: runFullAnalysis,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [kAccent, Color(0xFF00A884)],
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: kAccent.withOpacity(0.4), blurRadius: 20, spreadRadius: 2)],
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.upload_file_rounded, color: kPrimary),
                SizedBox(width: 10),
                Text("Upload CSV to Begin",
                    style: TextStyle(color: kPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
              ]),
            ),
          ),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: _showSampleCsvDialog,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kAccent.withOpacity(0.4)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.download_rounded, color: kAccent.withOpacity(0.7), size: 15),
                const SizedBox(width: 8),
                Text("Download Sample CSV",
                    style: TextStyle(color: kAccent.withOpacity(0.7), fontSize: 13)),
              ]),
            ),
          ),
        ],
      ),
    );
  }
 
  Widget _featureChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kAccent.withOpacity(0.2)),
      ),
      child: Row(children: [
        Icon(icon, size: 14, color: kAccent),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.white)),
      ]),
    );
  }
 
  // ── Main content ─────────────────────────────
  Widget _buildContent() {
    return FadeTransition(
      opacity: isLoading ? const AlwaysStoppedAnimation(1) : _fadeAnim,
      child: Column(children: [
 
        // Summary bar
        if (summary.isNotEmpty) _buildSummaryBar(),
 
        // Tab bar
        if (shipments.isNotEmpty) _buildTabBar(),
 
        // Tab content
        Expanded(
          child: _tabIndex == 0
              ? _buildAlertsList()
              : _buildShipmentsList(),
        ),
      ]),
    );
  }
 
  Widget _buildSummaryBar() {
    final total    = shipments.length;
    final critical = summary['critical'] ?? 0;
    final warning  = summary['warning']  ?? 0;
    final safe     = summary['safe']     ?? 0;
    final savings  = _totalSavings;
    final currency = _savingsCurrency;
    final savingsStr = savings >= 1000
        ? "${currency} ${(savings / 1000).toStringAsFixed(1)}K"
        : "${currency} ${savings.toStringAsFixed(0)}";

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
      ),
      child: Row(children: [
        _statBlock("$total",    "Total",    Colors.white),
        _divider(),
        _statBlock("$critical", "Critical", kCritical),
        _divider(),
        _statBlock("$warning",  "Warning",  kWarning),
        _divider(),
        _statBlock("$safe",     "Safe",     kSafe),
        _divider(),
        _statBlock(savings > 0 ? savingsStr : "—", "Saved", kAccent),
      ]),
    );
  }
 
  Widget _statBlock(String value, String label, Color color) {
    return Expanded(child: Column(children: [
      Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
      const SizedBox(height: 2),
      Text(label, style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.4))),
    ]));
  }
 
  Widget _divider() => Container(width: 1, height: 36, color: Colors.white.withOpacity(0.08));
 
  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
      ),
      child: Row(children: [
        _tab(0, Icons.warning_amber_rounded, "AI Alerts", alerts.where((a) => a['flag'] != 'Safe').length),
        _tab(1, Icons.inventory_2_rounded, "All Shipments", shipments.length),
      ]),
    );
  }
 
  Widget _tab(int idx, IconData icon, String label, int count) {
    final selected = _tabIndex == idx;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tabIndex = idx),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.all(4),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? kAccent.withOpacity(0.15) : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: selected ? kAccent.withOpacity(0.4) : Colors.transparent),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 16, color: selected ? kAccent : Colors.white.withOpacity(0.4)),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(
              fontSize: 13, fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected ? kAccent : Colors.white.withOpacity(0.4),
            )),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: selected ? kAccent.withOpacity(0.2) : Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text("$count", style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.bold,
                color: selected ? kAccent : Colors.white.withOpacity(0.3),
              )),
            ),
          ]),
        ),
      ),
    );
  }
 
  // ── Alerts list ──────────────────────────────
  Widget _buildAlertsList() {
    final nonSafe = alerts.where((a) => a['flag'] != 'Safe').toList();
    if (nonSafe.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.check_circle_rounded, color: kSafe, size: 60),
          const SizedBox(height: 16),
          const Text("All Shipments Safe", style: TextStyle(fontSize: 18, color: Colors.white)),
          Text("No disruptions detected", style: TextStyle(color: Colors.white.withOpacity(0.4))),
        ]),
      );
    }
 
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
      itemCount: nonSafe.length,
      itemBuilder: (_, i) => _buildAlertCard(nonSafe[i]),
    );
  }
 
  Widget _buildAlertCard(Map alert) {
    final color     = flagColor(alert['flag'] ?? 'Safe');
    final origCost  = alert['original_cost'] as Map? ?? {};
    final altCost   = alert['alt_cost']      as Map? ?? {};
    final routeData = _routeCache[alert['shipment_id'] as String? ?? ''];
 
    return GestureDetector(
      onTap: () => _openRouteSheet(alert),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.3)),
          boxShadow: [BoxShadow(color: color.withOpacity(0.05), blurRadius: 12, spreadRadius: 1)],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: color.withOpacity(0.08),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                border: Border(bottom: BorderSide(color: color.withOpacity(0.15))),
              ),
              child: Row(children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(flagIcon(alert['flag'] ?? 'Safe'), color: color, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(alert['shipment_id'] ?? '',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white)),
                  Text(alert['route'] ?? '',
                      style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.5))),
                ])),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: color.withOpacity(0.3)),
                    ),
                    child: Text(alert['flag'] ?? '',
                        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                  const SizedBox(height: 4),
                  Text("${alert['risk_score'] ?? 0}/100",
                      style: TextStyle(fontSize: 11, color: color.withOpacity(0.7))),
                  if (routeData != null) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: kAccent.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: kAccent.withOpacity(0.4)),
                      ),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.alt_route_rounded, size: 10, color: kAccent),
                        SizedBox(width: 4),
                        Text("AI-Rerouted",
                            style: TextStyle(color: kAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                      ]),
                    ),
                  ],
                ]),
              ]),
            ),
 
            // Alert text
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(alert['alert'] ?? '',
                    style: const TextStyle(fontSize: 13, color: Colors.white, height: 1.5)),

                // ML prediction row
                if (_predictions.containsKey(alert['shipment_id'])) ...[
                  const SizedBox(height: 10),
                  _buildAlertPredictionRow(alert['shipment_id'] as String),
                ],

                const SizedBox(height: 12),

                // Cost comparison row
                if (origCost.isNotEmpty) Row(children: [
                  Expanded(child: _costMini(
                    "Original Route",
                    "${origCost['currency']} ${_fmt(origCost['total_cost'])}",
                    kCritical, Icons.route,
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: _costMini(
                    "Alternative Route",
                    "${altCost['currency'] ?? ''} ${_fmt(altCost['total_cost'])}",
                    kSafe, Icons.alt_route_rounded,
                  )),
                ]),
 
                // Inline route optimisation result
                if (routeData != null) ...[
                  const SizedBox(height: 10),
                  _buildInlineRoutePanel(routeData),
                ],

                const SizedBox(height: 10),

                // Tap hint
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Text("Tap to view full details",
                      style: TextStyle(fontSize: 11, color: kAccent.withOpacity(0.7))),
                  const SizedBox(width: 4),
                  Icon(Icons.arrow_forward_ios_rounded, size: 10, color: kAccent.withOpacity(0.7)),
                ]),
              ]),
            ),
          ],
        ),
      ),
    );
  }
 
  Widget _costMini(String label, String value, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.4))),
          Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
        ])),
      ]),
    );
  }
 
  Widget _buildInlineRoutePanel(Map routeData) {
    final orig    = routeData['original']    as Map? ?? {};
    final alt     = routeData['alternative'] as Map? ?? {};
    final savings = routeData['savings']     as Map? ?? {};
    final rec     = routeData['recommendation'] as String? ?? '';

    final origKm  = (orig['distance_km'] as num?)?.toStringAsFixed(0) ?? '—';
    final altKm   = (alt['distance_km']  as num?)?.toStringAsFixed(0) ?? '—';
    final origHrs = (orig['duration_hr'] as num?)?.toStringAsFixed(1) ?? '—';
    final altHrs  = (alt['duration_hr']  as num?)?.toStringAsFixed(1) ?? '—';

    final distSaved        = ((orig['distance_km'] as num? ?? 0) - (alt['distance_km'] as num? ?? 0));
    final delayAvoided     = (savings['delay_avoided_min'] as num?)?.toInt();
    final co2Saved         = savings['co2_saved_kg'];
    final currency         = (savings['currency'] as String?) ?? '';
    final costSaved        = savings['cost'];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kAccent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kAccent.withValues(alpha: 0.2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.auto_fix_high_rounded, size: 13, color: kAccent),
          const SizedBox(width: 6),
          const Text("AI-Optimized Route",
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: kAccent)),
          const Spacer(),
          if (distSaved > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: kSafe.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                "−${distSaved.toStringAsFixed(0)} km"
                "${delayAvoided != null && delayAvoided > 0 ? '  −${delayAvoided}min delay' : ''}",
                style: const TextStyle(fontSize: 10, color: kSafe, fontWeight: FontWeight.bold),
              ),
            ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _routeStat("Original", "$origKm km", "$origHrs hrs",
              Colors.white.withValues(alpha: 0.5))),
          const SizedBox(width: 8),
          const Icon(Icons.arrow_forward_rounded, size: 14, color: kAccent),
          const SizedBox(width: 8),
          Expanded(child: _routeStat("Best Route", "$altKm km", "$altHrs hrs", kAccent)),
        ]),
        if (co2Saved != null || costSaved != null) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 12, runSpacing: 4, children: [
            if (co2Saved != null)
              _inlineSavingBadge(Icons.eco_rounded, "$co2Saved kg CO₂", kSafe),
            if (costSaved != null && (costSaved as num) > 0)
              _inlineSavingBadge(Icons.savings_outlined,
                  "$currency ${_fmt(costSaved)}", kAccent),
          ]),
        ],
        if (rec.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(rec, style: TextStyle(fontSize: 11,
              color: Colors.white.withValues(alpha: 0.5), height: 1.4)),
        ],
      ]),
    );
  }

  Widget _inlineSavingBadge(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _routeStat(String label, String dist, String time, Color color) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 9, color: color.withOpacity(0.6))),
        const SizedBox(height: 2),
        Text(dist, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
        Text(time, style: TextStyle(fontSize: 10, color: color.withOpacity(0.7))),
      ]),
    );
  }

  // ── ML prediction helpers ────────────────────
  Widget _buildPredictionBadge(String shipmentId) {
    final pred = _predictions[shipmentId];
    if (pred == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text("—%", style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.3))),
        Text("delay risk", style: TextStyle(fontSize: 9, color: Colors.white.withOpacity(0.2))),
      ]);
    }
    final prob = ((pred['delay_probability'] as num?) ?? 0).toDouble();
    final probPct = (prob * 100).toStringAsFixed(0);
    final level = (pred['risk_level'] as String?) ?? 'low';
    final levelColor = level == 'high' ? kCritical : level == 'medium' ? kWarning : kSafe;

    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Text("$probPct%",
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: levelColor)),
      Text("delay risk", style: TextStyle(fontSize: 9, color: Colors.white.withOpacity(0.25))),
      const SizedBox(height: 3),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: levelColor.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(level.toUpperCase(),
            style: TextStyle(fontSize: 8, color: levelColor, fontWeight: FontWeight.bold)),
      ),
    ]);
  }

  Widget _buildAlertPredictionRow(String shipmentId) {
    final pred = _predictions[shipmentId];
    if (pred == null) return const SizedBox.shrink();
    final prob = ((pred['delay_probability'] as num?) ?? 0).toDouble();
    final probPct = (prob * 100).toStringAsFixed(0);
    final hours = ((pred['delay_hours'] as num?) ?? 0).toDouble();
    final level = (pred['risk_level'] as String?) ?? 'low';
    final levelColor = level == 'high' ? kCritical : level == 'medium' ? kWarning : kSafe;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: levelColor.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: levelColor.withOpacity(0.2)),
      ),
      child: Row(children: [
        Icon(Icons.psychology_rounded, size: 14, color: levelColor),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text("ML Prediction",
              style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.4))),
          Text(
            "$probPct% delay probability  •  +${hours.toStringAsFixed(1)} hrs",
            style: TextStyle(fontSize: 12, color: levelColor, fontWeight: FontWeight.w600),
          ),
        ])),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: levelColor.withOpacity(0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(level.toUpperCase(),
              style: TextStyle(fontSize: 10, color: levelColor, fontWeight: FontWeight.bold)),
        ),
      ]),
    );
  }

  // ── Shipments list ───────────────────────────
  Widget _buildShipmentsList() {
    final filtered = _filteredShipments;
    return Column(children: [
      _buildShipmentsToolbar(),
      const SizedBox(height: 8),
      Expanded(
        child: filtered.isEmpty
            ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.search_off_rounded, color: Colors.white.withOpacity(0.2), size: 48),
                const SizedBox(height: 12),
                Text("No shipments match your filters",
                    style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 14)),
              ]))
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                itemCount: filtered.length,
                itemBuilder: (_, i) => _buildShipmentCard(filtered[i] as Map),
              ),
      ),
    ]);
  }

  Widget _buildShipmentsToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(children: [
        Container(
          decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: TextField(
            controller: _searchCtrl,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: "Search shipment ID, route, or cargo...",
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 13),
              prefixIcon: Icon(Icons.search_rounded, color: kAccent.withOpacity(0.6), size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? GestureDetector(
                      onTap: () => setState(() { _searchCtrl.clear(); _searchQuery = ''; }),
                      child: Icon(Icons.close_rounded, color: Colors.white.withOpacity(0.4), size: 18),
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onChanged: (v) => setState(() => _searchQuery = v),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                _filterChip('All', Colors.white),
                const SizedBox(width: 6),
                _filterChip('Critical', kCritical),
                const SizedBox(width: 6),
                _filterChip('Warning', kWarning),
                const SizedBox(width: 6),
                _filterChip('Safe', kSafe),
              ]),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _sortMode,
                dropdownColor: kSurface,
                iconEnabledColor: kAccent,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                items: const [
                  DropdownMenuItem(value: 'risk_desc',     child: Text('Risk ▼')),
                  DropdownMenuItem(value: 'risk_asc',      child: Text('Risk ▲')),
                  DropdownMenuItem(value: 'distance_desc', child: Text('Distance ▼')),
                  DropdownMenuItem(value: 'id_asc',        child: Text('ID A→Z')),
                ],
                onChanged: (v) => setState(() => _sortMode = v ?? 'risk_desc'),
              ),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _filterChip(String label, Color color) {
    final selected = _filterFlag == label;
    return GestureDetector(
      onTap: () => setState(() => _filterFlag = label),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color.withOpacity(0.2) : kCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? color : Colors.white.withOpacity(0.1)),
        ),
        child: Text(label, style: TextStyle(
          fontSize: 12,
          color: selected ? color : Colors.white.withOpacity(0.4),
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        )),
      ),
    );
  }
 
  Widget _buildShipmentCard(Map s) {
    final color = flagColor(s['flag'] ?? 'Safe');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(children: [
        // Risk score circle
        Container(
          width: 52, height: 52,
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            shape: BoxShape.circle,
            border: Border.all(color: color.withOpacity(0.4), width: 1.5),
          ),
          child: Center(child: Text(
            "${s['risk_score']}",
            style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 16),
          )),
        ),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(s['shipment_id'] ?? '',
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(s['flag'] ?? '',
                  style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 10)),
            ),
          ]),
          const SizedBox(height: 3),
          Text(s['route'] ?? '',
              style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.5))),
          const SizedBox(height: 3),
          Text(
            "${s['cargo_type'] ?? ''}  •  ${s['origin_country'] ?? ''}→${s['dest_country'] ?? ''}  •  ${_fmt(s['distance_km']?.toInt())} km",
            style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.35)),
          ),
        ])),
        _buildPredictionBadge(s['shipment_id'] as String? ?? ''),
      ]),
    );
  }
 
  String _fmt(dynamic val) {
    if (val == null) return "N/A";
    if (val is double) return val.toStringAsFixed(0);
    return val.toString();
  }
}
 
// ─────────────────────────────────────────────
// ROUTE DETAIL BOTTOM SHEET
// ─────────────────────────────────────────────
class RouteDetailSheet extends StatefulWidget {
  final Map alert;
  final Dio dio;
  final String baseUrl;
 
  const RouteDetailSheet({
    super.key,
    required this.alert,
    required this.dio,
    required this.baseUrl,
  });
 
  @override
  State<RouteDetailSheet> createState() => _RouteDetailSheetState();
}
 
class _RouteDetailSheetState extends State<RouteDetailSheet> {
  bool _loadingRoute = false;
  Map? _routeData;
 
  @override
  void initState() {
    super.initState();
    _fetchRoute();
  }
 
  Future<void> _fetchRoute() async {
    setState(() => _loadingRoute = true);
    try {
      final res = await widget.dio.post(
        "/route/optimize",
        queryParameters: {
          "shipment_id": widget.alert['shipment_id'],
          "origin":      widget.alert['origin'] ?? widget.alert['route']?.toString().split(' → ')[0],
          "destination": widget.alert['destination'] ?? widget.alert['route']?.toString().split(' → ')[1],
        },
      );
      setState(() { _routeData = res.data; _loadingRoute = false; });
    } catch (_) {
      setState(() => _loadingRoute = false);
    }
  }
 

 
  @override
  Widget build(BuildContext context) {
    final alert    = widget.alert;
    final color    = alert['flag'] == 'Critical' ? kCritical
                   : alert['flag'] == 'Warning'  ? kWarning : kSafe;
    final origCost = alert['original_cost'] as Map? ?? {};
    final altCost  = alert['alt_cost']      as Map? ?? {};
    final currency = origCost['currency'] ?? 'USD';
 
    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scroll) => Container(
        decoration: const BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(children: [
          // Handle
          Container(margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(2))),
 
          Expanded(child: ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(20, 0, 20, 30), children: [
 
            // Title
            Row(children: [
              Container(width: 40, height: 40,
                decoration: BoxDecoration(color: color.withOpacity(0.15), shape: BoxShape.circle),
                child: Icon(Icons.local_shipping_rounded, color: color, size: 22)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(alert['shipment_id'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white)),
                Text(alert['route'] ?? '', style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 13)),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(20), border: Border.all(color: color.withOpacity(0.3))),
                child: Text(alert['flag'] ?? '', style: TextStyle(color: color, fontWeight: FontWeight.bold)),
              ),
            ]),
 
            const SizedBox(height: 20),
 
            // AI Alert
            _section("AI Alert", Icons.auto_awesome_rounded, kAccent,
              Text(alert['alert'] ?? '', style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.6))),
 
            const SizedBox(height: 16),
 
            // Delay reason
            _section("Why This Delay", Icons.info_outline_rounded, kWarning,
              Text(alert['delay_reason'] ?? 'Adverse weather conditions on route',
                  style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.5))),
 
            const SizedBox(height: 16),
 
            // Cost comparison
            _section("Route Cost Comparison", Icons.attach_money_rounded, kSafe,
              Column(children: [
                _costRow("Fuel Cost",   origCost['fuel_cost'],   altCost['fuel_cost'],   currency),
                _costRow("Toll Cost",   origCost['toll_cost'],   altCost['toll_cost'],   currency),
                _costRow("Driver Cost", origCost['driver_cost'], altCost['driver_cost'], currency),
                const Divider(color: Colors.white12),
                _costRow("Total Cost",  origCost['total_cost'],  altCost['total_cost'],  currency, bold: true),
                if ((origCost['total_cost'] ?? 0) > (altCost['total_cost'] ?? 0)) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: kSafe.withOpacity(0.1), borderRadius: BorderRadius.circular(10), border: Border.all(color: kSafe.withOpacity(0.2))),
                    child: Row(children: [
                      const Icon(Icons.savings_rounded, color: kSafe, size: 16),
                      const SizedBox(width: 8),
                      Text("Alternative saves $currency ${_fmtNum((origCost['total_cost'] ?? 0) - (altCost['total_cost'] ?? 0))}",
                          style: const TextStyle(color: kSafe, fontWeight: FontWeight.bold, fontSize: 13)),
                    ]),
                  ),
                ],
              ])),
 
            const SizedBox(height: 16),
 
            // Route info from Layer 2
            if (_loadingRoute)
              const Center(child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(color: kAccent),
              ))
            else if (_routeData != null)
              _section("Route Details", Icons.route_rounded, const Color(0xFF7B68EE),
                Column(children: [
                  _routeRow("Original Distance", "${_routeData!['original']['distance_km']} km"),
                  _routeRow("Original Duration", "${_routeData!['original']['duration_hr']} hrs"),
                  _routeRow("Alternative Distance", "${_routeData!['alternative']['distance_km']} km"),
                  _routeRow("Alternative Duration", "${_routeData!['alternative']['duration_hr']} hrs"),
                  _routeRow("Time Saved", "${_routeData!['alternative']['time_saved']} min"),
                  const SizedBox(height: 8),
                  Text(_routeData!['recommendation'] ?? '',
                      style: TextStyle(color: kAccent.withOpacity(0.8), fontSize: 13)),
                ])),
 
            const SizedBox(height: 20),

            // View optimized routes on map
            if (_routeData != null)
              GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => MapScreen(
                    routeData:  Map<String, dynamic>.from(_routeData!),
                    shipmentId: alert['shipment_id'] as String? ?? '',
                    routeLabel: alert['route']       as String? ?? '',
                  ),
                )),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: kCard,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: kAccent.withOpacity(0.4)),
                  ),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.route_rounded, color: kAccent, size: 20),
                    SizedBox(width: 10),
                    Text("View Optimized Routes Map",
                        style: TextStyle(color: kAccent, fontWeight: FontWeight.bold, fontSize: 14)),
                  ]),
                ),
              ),

          ])),
        ]),
      ),
    );
  }
 
  Widget _section(String title, IconData icon, Color color, Widget child) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
        ]),
        const SizedBox(height: 10),
        child,
      ]),
    );
  }
 
  Widget _costRow(String label, dynamic orig, dynamic alt, String currency, {bool bold = false}) {
    final o = orig ?? 0;
    final a = alt  ?? 0;
    final saved = (o - a);
 
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Expanded(child: Text(label, style: TextStyle(
            color: Colors.white.withOpacity(0.6), fontSize: 13,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal))),
        Text("$currency ${_fmtNum(o)}",
            style: TextStyle(color: kCritical, fontSize: 13, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        const SizedBox(width: 12),
        Text("$currency ${_fmtNum(a)}",
            style: TextStyle(color: kSafe, fontSize: 13, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        if (saved != 0) ...[
          const SizedBox(width: 8),
          Text("${saved > 0 ? '-' : '+'}${_fmtNum(saved.abs())}",
              style: TextStyle(fontSize: 11, color: saved > 0 ? kSafe : kCritical)),
        ],
      ]),
    );
  }
 
  Widget _routeRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(child: Text(label, style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 13))),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
      ]),
    );
  }
 
  String _fmtNum(dynamic val) {
    if (val == null) return "N/A";
    final n = (val is double) ? val.toInt() : (val as int);
    if (n >= 1000) return "${(n / 1000).toStringAsFixed(1)}K";
    return n.toString();
  }
}
 
// ─────────────────────────────────────────────
// CHATBOT BOTTOM SHEET
// ─────────────────────────────────────────────
class ChatbotSheet extends StatefulWidget {
  final List shipments;
  final List alerts;
 
  const ChatbotSheet({super.key, required this.shipments, required this.alerts});
 
  @override
  State<ChatbotSheet> createState() => _ChatbotSheetState();
}
 
class _ChatbotSheetState extends State<ChatbotSheet> {
  final List<Map<String, String>> _messages = [];
 
  final List<String> _quickQuestions = [
    "What caused the delays?",
    "Which shipment has the highest risk?",
    "What is the new route?",
    "How much can we save?",
    "How many critical alerts?",
    "What is the safest shipment?",
  ];
 
  @override
  void initState() {
    super.initState();
    _messages.add({
      "role": "bot",
      "text": "Hello! I'm your AI Supply Chain Assistant. Ask me anything about your shipments, or tap a quick question below.",
    });
  }
 
  String _generateAnswer(String question) {
    final q = question.toLowerCase();
 
    if (q.contains("delay") || q.contains("cause") || q.contains("why")) {
      if (widget.alerts.isEmpty) return "No disruptions detected yet. Upload a CSV to analyze shipments.";
      final critical = widget.alerts.where((a) => a['flag'] == 'Critical').toList();
      if (critical.isEmpty) return "No critical delays found. All shipments are at Warning or Safe level.";
      final reasons = critical.take(3).map((a) => "• ${a['shipment_id']}: ${a['delay_reason'] ?? 'adverse weather'}").join("\n");
      return "Top delay causes:\n$reasons";
    }
 
    if (q.contains("highest risk") || q.contains("worst") || q.contains("most critical")) {
      if (widget.shipments.isEmpty) return "No shipment data loaded yet.";
      final top = widget.shipments.first;
      return "Highest risk shipment:\n• ID: ${top['shipment_id']}\n• Route: ${top['route']}\n• Risk Score: ${top['risk_score']}/100\n• Flag: ${top['flag']}\n• Reason: ${top['delay_reason'] ?? 'weather conditions'}";
    }
 
    if (q.contains("new route") || q.contains("alternative") || q.contains("reroute")) {
      final critical = widget.alerts.where((a) => a['flag'] != 'Safe').take(2).toList();
      if (critical.isEmpty) return "No rerouting needed — all shipments are on their optimal routes.";
      final info = critical.map((a) {
        final alt = a['alt_cost'] as Map? ?? {};
        return "• ${a['shipment_id']} (${a['route']}): Alternative route via detour — ${alt['currency'] ?? ''} ${alt['total_cost'] ?? 'N/A'} total cost";
      }).join("\n");
      return "Recommended alternative routes:\n$info\nTap any alert card for full route details and Google Maps navigation.";
    }
 
    if (q.contains("save") || q.contains("cost") || q.contains("cheap")) {
      if (widget.alerts.isEmpty) return "No data available. Please upload a CSV first.";
      int totalSaving = 0;
      for (final a in widget.alerts) {
        final orig = (a['original_cost'] as Map?)?['total_cost'] ?? 0;
        final alt  = (a['alt_cost']      as Map?)?['total_cost'] ?? 0;
        if (orig > alt) totalSaving += (orig - alt) as int;
      }
      final currency = (widget.alerts.first['original_cost'] as Map?)?['currency'] ?? 'USD';
      return "By taking alternative routes for all disrupted shipments, you can save approximately $currency ${totalSaving.toString()} in total route costs (fuel + tolls + driver combined).";
    }
 
    if (q.contains("critical") || q.contains("how many")) {
      final critical = widget.alerts.where((a) => a['flag'] == 'Critical').length;
      final warning  = widget.alerts.where((a) => a['flag'] == 'Warning').length;
      final safe     = widget.alerts.where((a) => a['flag'] == 'Safe').length;
      return "Current status:\n• Critical: $critical shipment(s) — immediate action required\n• Warning: $warning shipment(s) — monitor closely\n• Safe: $safe shipment(s) — on schedule\n\nTotal analyzed: ${widget.shipments.length} shipments";
    }
 
    if (q.contains("safe") || q.contains("safest")) {
      final safeList = widget.shipments.where((s) => s['flag'] == 'Safe').toList();
      if (safeList.isEmpty) return "No safe shipments at the moment.";
      final best = safeList.last;
      return "Safest shipment:\n• ID: ${best['shipment_id']}\n• Route: ${best['route']}\n• Risk Score: ${best['risk_score']}/100\n• Status: On schedule, no disruptions";
    }
 
    // Unknown question — show contact
    return "I can only answer questions about your current shipments.\n\nFor other queries, please contact our support team:\n\n📧 support@smartsupplychain.ai\n📞 +1-800-SUPPLY-1\n🕐 Mon–Fri, 9AM–6PM UTC\n\nOr visit our help center at help.smartsupplychain.ai";
  }
 
  void _ask(String question) {
    setState(() {
      _messages.add({"role": "user", "text": question});
      final answer = _generateAnswer(question);
      _messages.add({"role": "bot", "text": answer});
    });
  }
 
  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scroll) => Container(
        decoration: const BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(children: [
          // Handle
          Container(margin: const EdgeInsets.only(top: 12, bottom: 4),
              width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(2))),
 
          // Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(children: [
              Container(width: 36, height: 36,
                decoration: const BoxDecoration(color: Color(0x22000000), shape: BoxShape.circle),
                child: const Icon(Icons.smart_toy_rounded, color: kAccent, size: 20)),
              const SizedBox(width: 10),
              const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text("AI Supply Chain Assistant",
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 15)),
                Text("Powered by local intelligence",
                    style: TextStyle(fontSize: 11, color: Colors.white38)),
              ]),
            ]),
          ),
 
          const Divider(color: Colors.white10),
 
          // Messages
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (_, i) {
                final msg   = _messages[i];
                final isBot = msg['role'] == 'bot';
                return Align(
                  alignment: isBot ? Alignment.centerLeft : Alignment.centerRight,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
                    decoration: BoxDecoration(
                      color: isBot ? kCard : kAccent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: isBot ? Colors.white12 : kAccent.withOpacity(0.3)),
                    ),
                    child: Text(msg['text'] ?? '',
                        style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.5)),
                  ),
                );
              },
            ),
          ),
 
          // Quick questions
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text("Quick questions",
                  style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.35))),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: _quickQuestions.map((q) => GestureDetector(
                  onTap: () => _ask(q),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: kCard,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: kAccent.withOpacity(0.25)),
                    ),
                    child: Text(q, style: const TextStyle(fontSize: 12, color: Colors.white)),
                  ),
                )).toList(),
              ),
              const SizedBox(height: 12),
            ]),
          ),
        ]),
      ),
    );
  }
}
