import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';

class ApiService {
  static const String baseUrl = "http://127.0.0.1:8000";
  final Dio _dio = Dio();

  // Layer 0 — upload CSV
  Future<Map<String, dynamic>> uploadShipments(PlatformFile file) async {
    FormData formData = FormData.fromMap({
      "file": MultipartFile.fromBytes(file.bytes!, filename: file.name),
    });
    final response = await _dio.post("$baseUrl/ingest/upload", data: formData);
    return response.data;
  }

  // Layer 1 — detect disruptions
  Future<Map<String, dynamic>> detectDisruptions() async {
    final response = await _dio.post("$baseUrl/detect/disruptions");
    return response.data;
  }

  // Layer 2 — optimize route
  Future<Map<String, dynamic>> optimizeRoute(
      String shipmentId, String origin, String destination) async {
    final response = await _dio.post(
      "$baseUrl/route/optimize",
      queryParameters: {
        "shipment_id": shipmentId,
        "origin": origin,
        "destination": destination,
      },
    );
    return response.data;
  }

  // Layer 3 — ML risk scores
  Future<Map<String, dynamic>> getRiskScores() async {
    final response = await _dio.post("$baseUrl/risk/score");
    return response.data;
  }

  // Layer 4 — AI alerts
  Future<Map<String, dynamic>> generateAlerts() async {
    final response = await _dio.post("$baseUrl/alerts/generate");
    return response.data;
  }
}