import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class BackendApi {
  BackendApi({
    required this.commsBaseUrl,
    required this.locationBaseUrl,
  });

  final String commsBaseUrl;
  final String locationBaseUrl;

  Uri _commsUri(String path, [Map<String, String>? query]) =>
      Uri.parse('$commsBaseUrl$path').replace(queryParameters: query);
  Uri _locationUri(String path, [Map<String, String>? query]) =>
      Uri.parse('$locationBaseUrl$path').replace(queryParameters: query);

  /// Avoid [FormatException] when the server returns an empty body or HTML (wrong route / proxy).
  Map<String, dynamic>? _decodeJsonObject(String body) {
    final t = body.trim();
    if (t.isEmpty) return null;
    try {
      final v = jsonDecode(t);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return Map<String, dynamic>.from(v);
      return null;
    } catch (_) {
      return null;
    }
  }

  String _responseHint(String body, {int max = 120}) {
    final t = body.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.isEmpty) return '(empty body)';
    return t.length <= max ? t : '${t.substring(0, max)}…';
  }

  Future<List<Map<String, dynamic>>> getChannels() async {
    final res = await http.get(_commsUri('/channels'));
    if (res.statusCode ~/ 100 != 2) {
      throw Exception('getChannels failed: ${res.statusCode}');
    }
    return (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> createChannel({
    required String name,
    required bool isPrivate,
    String? createdByUserId,
  }) async {
    final res = await http.post(
      _commsUri('/channels'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': name,
        'isPrivate': isPrivate,
        'createdByUserId': createdByUserId,
      }),
    );
    if (res.statusCode ~/ 100 != 2) {
      throw Exception('createChannel failed: ${res.statusCode}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> getMessages(String channelId) async {
    final res = await http.get(_commsUri('/messages', {'channelId': channelId}));
    if (res.statusCode ~/ 100 != 2) {
      throw Exception('getMessages failed: ${res.statusCode}');
    }
    return (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> sendMessage({
    required String channelId,
    required String sender,
    required String kind,
    required String encryptedPayload,
  }) async {
    final res = await http.post(
      _commsUri('/messages'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'channelId': channelId,
        'sender': sender,
        'kind': kind,
        'encryptedPayload': encryptedPayload,
      }),
    );
    if (res.statusCode ~/ 100 != 2) {
      throw Exception('sendMessage failed: ${res.statusCode}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<void> upsertLocation({
    required String userId,
    required double lat,
    required double lng,
  }) async {
    final res = await http.post(
      _locationUri('/locations'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'userId': userId, 'lat': lat, 'lng': lng}),
    );
    if (res.statusCode ~/ 100 != 2) {
      throw Exception('upsertLocation failed: ${res.statusCode}');
    }
  }

  Future<List<Map<String, dynamic>>> getLocations() async {
    final res = await http.get(_locationUri('/locations'));
    if (res.statusCode ~/ 100 != 2) {
      throw Exception('getLocations failed: ${res.statusCode}');
    }
    return (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getTrips({required String userId}) async {
    final res = await http.get(_locationUri('/trips', {'userId': userId}));
    if (res.statusCode ~/ 100 != 2) {
      throw Exception('getTrips failed: ${res.statusCode}');
    }
    return (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> signUp({
    required String username,
    required String password,
  }) async {
    final res = await http.post(
      _locationUri('/auth/signup'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );
    final body = _decodeJsonObject(res.body);
    if (res.statusCode == 201) {
      if (body == null) {
        throw Exception(
          'Sign up returned 201 but response was not JSON. Check LOCATION_API_BASE_URL and that auth routes are deployed.',
        );
      }
      return body;
    }
    final msg = body?['error'] as String?;
    throw Exception(
      msg ??
          'Sign up failed (HTTP ${res.statusCode}). ${_responseHint(res.body)} — deploy backend with /auth/signup or verify the API URL.',
    );
  }

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    final res = await http.post(
      _locationUri('/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );
    final body = _decodeJsonObject(res.body);
    if (res.statusCode == 200) {
      if (body == null) {
        throw Exception(
          'Login returned 200 but response was not JSON. Check LOCATION_API_BASE_URL and auth deployment.',
        );
      }
      return body;
    }
    final msg = body?['error'] as String?;
    throw Exception(
      msg ??
          'Login failed (HTTP ${res.statusCode}). ${_responseHint(res.body)}',
    );
  }

  Future<Map<String, dynamic>> verifySession(String token) async {
    final res = await http.get(_locationUri('/auth/session', {'token': token}));
    if (res.statusCode ~/ 100 != 2) {
      throw Exception('Session check failed: ${res.statusCode}');
    }
    final body = _decodeJsonObject(res.body);
    if (body == null) {
      throw Exception(
        'Session check returned non-JSON. ${_responseHint(res.body)}',
      );
    }
    return body;
  }

  Future<Map<String, dynamic>> saveTrip({
    required String userId,
    required Map<String, dynamic> payload,
  }) async {
    final res = await http.post(
      _locationUri('/trips'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({...payload, 'userId': userId}),
    );
    if (res.statusCode ~/ 100 != 2) {
      throw Exception('saveTrip failed: ${res.statusCode} ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getAcsToken({
    required String displayName,
    required String channelId,
  }) async {
    final res = await http.post(
      _commsUri('/acs/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'displayName': displayName,
        'channelId': channelId,
      }),
    );
    if (res.statusCode ~/ 100 != 2) {
      throw Exception('getAcsToken failed: ${res.statusCode}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<String> uploadMedia({
    required String userId,
    required String fileName,
    required String category,
    required Uint8List bytes,
    required String contentType,
  }) async {
    final res = await http.post(
      _commsUri('/media/upload'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'userId': userId,
        'fileName': fileName,
        'category': category,
        'base64Data': base64Encode(bytes),
        'contentType': contentType,
      }),
    );
    if (res.statusCode ~/ 100 != 2) {
      throw Exception('uploadMedia failed: ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['url'] as String;
  }
}
