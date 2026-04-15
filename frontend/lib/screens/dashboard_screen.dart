import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
 
// ─────────────────────────────────────────────
// CONSTANTS
// ─────────────────────────────────────────────
const String kBaseUrl   = "http://127.0.0.1:8000";
const Color  kPrimary   = Color(0xFF0A1628);
const Color  kAccent    = Color(0xFF00D4AA);
const Color  kCard      = Color(0xFF0F2040);
const Color  kSurface   = Color(0xFF142848);
const Color  kCritical  = Color(0xFFFF4757);
const Color  kWarning   = Color(0xFFFFB300);
const Color  kSafe      = Color(0xFF00D4AA);
 
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
 
  final Dio _dio = Dio();
  bool   isLoading  = false;
  String statusMsg  = "";
  int    currentStep = 0;
  int    _tabIndex   = 0;
 
  List shipments = [];
  List alerts    = [];
  Map  summary   = {};
 
  late AnimationController _pulseCtrl;
  late AnimationController _fadeCtrl;
  late Animation<double>   _fadeAnim;
 
  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _fadeCtrl  = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 800));
    _fadeAnim  = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeIn);
  }
 
  @override
  void dispose() {
    _pulseCtrl.dispose();
    _fadeCtrl.dispose();
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
 
    setState(() {
      isLoading  = true;
      currentStep = 0;
      shipments  = [];
      alerts     = [];
      summary    = {};
      statusMsg  = "Initializing analysis pipeline...";
    });
 
    try {
      // Layer 0
      setState(() { statusMsg = "Layer 0 — Ingesting shipment data..."; currentStep = 1; });
      FormData formData = FormData.fromMap({
        "file": MultipartFile.fromBytes(file.bytes!, filename: file.name),
      });
      await _dio.post("$kBaseUrl/ingest/upload", data: formData);
 
      // Layer 1
      setState(() { statusMsg = "Layer 1 — Detecting weather disruptions..."; currentStep = 2; });
      await _dio.post("$kBaseUrl/detect/disruptions");
 
      // Layer 3
      setState(() { statusMsg = "Layer 3 — Running ML risk model..."; currentStep = 3; });
      final l3 = await _dio.post("$kBaseUrl/risk/score");
 
      // Layer 4
      setState(() { statusMsg = "Layer 4 — Generating AI alerts..."; currentStep = 4; });
      final l4 = await _dio.post("$kBaseUrl/alerts/generate");
 
      setState(() {
        isLoading   = false;
        statusMsg   = "Analysis complete — ${(l3.data['shipments'] as List).length} shipments processed";
        shipments   = l3.data['shipments'] ?? [];
        alerts      = l4.data['alerts']    ?? [];
        summary     = l3.data['summary']   ?? {};
        currentStep = 5;
      });
      _fadeCtrl.forward(from: 0);
 
    } catch (e) {
      setState(() {
        isLoading = false;
        statusMsg = "Error: ${e.toString()}";
      });
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
        baseUrl: kBaseUrl,
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
    final steps = ["Upload", "Weather", "ML Model", "AI Alerts", "Done"];
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
        _statBlock(
          "${critical > 0 ? ((critical / total) * 100).toStringAsFixed(0) : 0}%",
          "At Risk", kCritical,
        ),
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
    final color = flagColor(alert['flag'] ?? 'Safe');
    final origCost = alert['original_cost'] as Map? ?? {};
    final altCost  = alert['alt_cost']      as Map? ?? {};
 
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
                ]),
              ]),
            ),
 
            // Alert text
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(alert['alert'] ?? '',
                    style: const TextStyle(fontSize: 13, color: Colors.white, height: 1.5)),
 
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
 
                const SizedBox(height: 10),
 
                // Tap hint
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Text("Tap to view route details",
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
 
  // ── Shipments list ───────────────────────────
  Widget _buildShipmentsList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
      itemCount: shipments.length,
      itemBuilder: (_, i) => _buildShipmentCard(shipments[i]),
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
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text("${s['confidence'] ?? 'N/A'}%",
              style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.4))),
          Text("confidence", style: TextStyle(fontSize: 9, color: Colors.white.withOpacity(0.25))),
        ]),
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
        "${widget.baseUrl}/route/optimize",
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
 
  void _openGoogleMaps(double oLat, double oLon, double dLat, double dLon) async {
    final url = "https://www.google.com/maps/dir/?api=1"
        "&origin=$oLat,$oLon"
        "&destination=$dLat,$dLon"
        "&travelmode=driving";
    if (await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
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
 
            // Open in Google Maps button
            GestureDetector(
              onTap: () => _openGoogleMaps(
                (alert['origin_lat'] ?? 0).toDouble(),
                (alert['origin_lon'] ?? 0).toDouble(),
                (alert['dest_lat']   ?? 0).toDouble(),
                (alert['dest_lon']   ?? 0).toDouble(),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [kAccent, Color(0xFF00A884)]),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [BoxShadow(color: kAccent.withOpacity(0.3), blurRadius: 15, spreadRadius: 1)],
                ),
                child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.map_rounded, color: kPrimary),
                  SizedBox(width: 10),
                  Text("View Route in Google Maps",
                      style: TextStyle(color: kPrimary, fontWeight: FontWeight.bold, fontSize: 15)),
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