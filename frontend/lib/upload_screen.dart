import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';

class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  bool isLoading = false;
  String statusMessage = "";
  Map<String, dynamic>? layer3Result;
  Map<String, dynamic>? summaryResult;

  final String baseUrl = "http://127.0.0.1:8000";

  Future<void> uploadCSV() async {
    FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
      withData: true,
    );

    if (picked == null) return;
    PlatformFile file = picked.files.single;
    if (file.bytes == null) return;

    setState(() {
      isLoading = true;
      statusMessage = "Layer 0 — Uploading shipment data...";
      layer3Result = null;
    });

    try {
      Dio dio = Dio();

      // Layer 0 — upload CSV
      FormData formData = FormData.fromMap({
        "file": MultipartFile.fromBytes(file.bytes!, filename: file.name),
      });
      await dio.post("$baseUrl/ingest/upload", data: formData);

      // Layer 1 — weather check
      setState(
        () => statusMessage = "Layer 1 — Checking weather disruptions...",
      );
      await dio.post("$baseUrl/detect/disruptions");

      // Layer 3 — ML risk scoring (has risk_score AND confidence)
      setState(() => statusMessage = "Layer 3 — Running ML risk model...");
      Response layer3 = await dio.post("$baseUrl/risk/score");

      setState(() {
        layer3Result = layer3.data;
        summaryResult = layer3.data['summary'];
        statusMessage = "✅ Completed!";
      });
    } catch (e) {
      setState(() => statusMessage = "❌ Error: $e");
    } finally {
      setState(() => isLoading = false);
    }
  }

  Color _flagColor(String flag) {
    if (flag == 'Critical') return Colors.red;
    if (flag == 'Warning') return Colors.orange;
    return Colors.green;
  }

  @override
  Widget build(BuildContext context) {
    // ✅ FIXED — reads from layer3Result['shipments'] not layer1Result['results']
    final shipments = (layer3Result?['shipments'] as List?) ?? [];

    return Scaffold(
      appBar: AppBar(
        title: const Text("Smart Supply Chain"),
        backgroundColor: const Color(0xFF1D9E75),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Upload button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: isLoading ? null : uploadCSV,
                icon: isLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.upload_file),
                label: Text(
                  isLoading ? statusMessage : "Upload CSV and Analyze",
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1D9E75),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            if (!isLoading && statusMessage.isNotEmpty)
              Text(
                statusMessage,
                style: TextStyle(
                  color: statusMessage.contains("Error")
                      ? Colors.red
                      : Colors.green,
                  fontWeight: FontWeight.w500,
                ),
              ),

            // Summary row
            if (summaryResult != null) ...[
              const SizedBox(height: 20),
              Row(
                children: [
                  _summaryCard("Total", "${shipments.length}", Colors.blue),
                  const SizedBox(width: 8),
                  _summaryCard(
                    "Critical",
                    "${summaryResult!['critical']}",
                    Colors.red,
                  ),
                  const SizedBox(width: 8),
                  _summaryCard(
                    "Warning",
                    "${summaryResult!['warning']}",
                    Colors.orange,
                  ),
                  const SizedBox(width: 8),
                  _summaryCard(
                    "Safe",
                    "${summaryResult!['safe']}",
                    Colors.green,
                  ),
                ],
              ),
            ],

            // Shipment cards
            if (shipments.isNotEmpty) ...[
              const SizedBox(height: 20),
              const Text(
                "Disruption Analysis",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),

              ...shipments.map((shipment) {
                final flag = shipment['flag'] ?? 'Safe';
                final color = _flagColor(flag);
                final confidence = shipment['confidence'];

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.07),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: color.withOpacity(0.35)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            shipment['shipment_id'] ?? '',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: color.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              flag,
                              style: TextStyle(
                                color: color,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        shipment['route'] ?? '',
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),

                      // ✅ confidence now shows correctly from layer3
                      Text(
                        "Risk: ${shipment['risk_score']}/100"
                        "  •  Confidence: ${confidence != null ? '$confidence%' : 'N/A'}"
                        "  •  ${shipment['recommended_action'] ?? ''}",
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  Widget _summaryCard(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: color.withOpacity(0.8)),
            ),
          ],
        ),
      ),
    );
  }
}
