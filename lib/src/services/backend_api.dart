import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';

class BackendApi {
  BackendApi()
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          sendTimeout: const Duration(seconds: 20),
          responseType: ResponseType.json,
          contentType: Headers.jsonContentType,
        ),
      );

  final Dio _dio;
  String _baseUrl = '';
  String? _token;

  void configure({required String baseUrl, String? token}) {
    _baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    _token = token;
  }

  Future<bool> probeBaseUrl(String baseUrl) async {
    final normalized = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$normalized/map/config',
        options: Options(
          sendTimeout: const Duration(milliseconds: 800),
          connectTimeout: const Duration(milliseconds: 800),
          receiveTimeout: const Duration(milliseconds: 800),
        ),
      );
      final payload = response.data ?? const <String, dynamic>{};
      return payload['provider'] != null && payload['tiles'] != null;
    } on DioException {
      return false;
    }
  }

  Future<AuthResult> register({
    required String name,
    required String email,
    required String password,
    required String passwordConfirmation,
    required String deviceName,
  }) async {
    final data = await _post(
      '/auth/register',
      data: {
        'name': name,
        'email': email,
        'password': password,
        'password_confirmation': passwordConfirmation,
        'device_name': deviceName,
      },
    );

    return AuthResult.fromJson(_expectMap(data));
  }

  Future<AuthResult> login({
    required String email,
    required String password,
    required String deviceName,
  }) async {
    final data = await _post(
      '/auth/login',
      data: {'email': email, 'password': password, 'device_name': deviceName},
    );

    return AuthResult.fromJson(_expectMap(data));
  }

  Future<AppUser> me() async {
    final data = await _get('/auth/me', authRequired: true);
    return AppUser.fromJson(_expectMap(data['user']));
  }

  Future<void> logout() async {
    await _post('/auth/logout', authRequired: true);
  }

  Future<MapConfig> getMapConfig() async {
    final data = await _get('/map/config');
    return MapConfig.fromJson(_expectMap(data));
  }

  Future<List<Territory>> listTerritories({
    bool mine = false,
    int perPage = 200,
  }) async {
    final data = await _get(
      '/territories',
      queryParameters: {'per_page': perPage, if (mine) 'mine': 1},
      authRequired: mine,
    );

    final payload = _expectMap(data);
    final items = payload['data'] as List?;
    if (items == null) {
      return const <Territory>[];
    }

    return items
        .whereType<Map<String, dynamic>>()
        .map(Territory.fromJson)
        .toList(growable: false);
  }

  Future<TrackingSession?> getActiveTrackingSession() async {
    final data = await _get('/tracking-sessions/active', authRequired: true);
    final payload = _expectMap(data);
    final raw = payload['data'];
    if (raw == null) {
      return null;
    }

    return TrackingSession.fromJson(_expectMap(raw));
  }

  Future<TrackingSession> startTracking({
    required RoutePoint startPoint,
  }) async {
    final data = await _post(
      '/tracking-sessions/start',
      authRequired: true,
      data: {'start_point': startPoint.toApiJson()},
    );

    final sessionMap = _unwrapData(_expectMap(data));
    return TrackingSession.fromJson(sessionMap);
  }

  Future<TrackingSession> getTrackingSession({required int sessionId}) async {
    final data = await _get(
      '/tracking-sessions/$sessionId',
      authRequired: true,
    );

    final sessionMap = _unwrapData(_expectMap(data));
    return TrackingSession.fromJson(sessionMap);
  }

  Future<void> appendTrackingPoints({
    required int sessionId,
    required List<RoutePoint> points,
  }) async {
    if (points.isEmpty) {
      return;
    }

    await _post(
      '/tracking-sessions/$sessionId/points',
      authRequired: true,
      data: {
        'points': points
            .map((point) => point.toApiJson())
            .toList(growable: false),
      },
    );
  }

  Future<FinishTrackingResult> finishTracking({
    required int sessionId,
    bool claimTerritory = true,
    String ownerVisibility = 'public',
    List<RoutePoint> points = const <RoutePoint>[],
  }) async {
    final data = await _post(
      '/tracking-sessions/$sessionId/finish',
      authRequired: true,
      data: {
        'claim_territory': claimTerritory,
        if (claimTerritory) 'owner_visibility': ownerVisibility,
        if (points.isNotEmpty)
          'points': points
              .map((point) => point.toApiJson())
              .toList(growable: false),
      },
    );

    final payload = _expectMap(data);
    final sessionMap = _unwrapData(_expectMap(payload['session']));
    final territoryRaw = payload['territory'];
    final territory = territoryRaw is Map<String, dynamic>
        ? Territory.fromJson(_unwrapData(_expectMap(territoryRaw)))
        : null;
    final claimed = payload['claimed'] == true || territory != null;
    final message = payload['message']?.toString();

    return FinishTrackingResult(
      session: TrackingSession.fromJson(sessionMap),
      territory: territory,
      claimed: claimed,
      message: message,
    );
  }

  Future<Map<String, dynamic>> _get(
    String path, {
    bool authRequired = false,
    Map<String, dynamic>? queryParameters,
  }) async {
    _assertConfigured();
    final url = _fullPath(path);
    debugPrint('[API] ┌── GET $url');
    if (queryParameters != null && queryParameters.isNotEmpty) {
      debugPrint('[API] │ params: $queryParameters');
    }
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        url,
        queryParameters: queryParameters,
        options: _options(authRequired: authRequired),
      );
      debugPrint('[API] │ status: ${response.statusCode}');
      debugPrint('[API] └── response: ${response.data}');
      return response.data ?? const <String, dynamic>{};
    } on DioException catch (error) {
      debugPrint('[API] │ status: ${error.response?.statusCode}');
      debugPrint('[API] └── error: ${error.response?.data ?? error.message}');
      throw _toApiError(error);
    }
  }

  Future<Map<String, dynamic>> _post(
    String path, {
    bool authRequired = false,
    Map<String, dynamic>? data,
  }) async {
    _assertConfigured();
    final url = _fullPath(path);
    debugPrint('[API] ┌── POST $url');
    if (data != null && data.isNotEmpty) {
      debugPrint('[API] │ body: $data');
    }
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        url,
        data: data ?? const <String, dynamic>{},
        options: _options(authRequired: authRequired),
      );
      debugPrint('[API] │ status: ${response.statusCode}');
      debugPrint('[API] └── response: ${response.data}');
      return response.data ?? const <String, dynamic>{};
    } on DioException catch (error) {
      debugPrint('[API] │ status: ${error.response?.statusCode}');
      debugPrint('[API] └── error: ${error.response?.data ?? error.message}');
      throw _toApiError(error);
    }
  }

  Options _options({required bool authRequired}) {
    final headers = <String, dynamic>{};
    if (authRequired) {
      if (_token == null || _token!.isEmpty) {
        throw const ApiError(
          'Bu işlem için giriş yapılması gerekiyor.',
          statusCode: 401,
        );
      }
      headers['Authorization'] = 'Bearer $_token';
    }

    return Options(headers: headers);
  }

  ApiError _toApiError(DioException error) {
    final statusCode = error.response?.statusCode;
    final responseData = error.response?.data;

    if (responseData is Map<String, dynamic>) {
      final message = responseData['message']?.toString();
      if (message != null && message.trim().isNotEmpty) {
        return ApiError(message, statusCode: statusCode);
      }

      final errors = responseData['errors'];
      if (errors is Map<String, dynamic>) {
        final firstError = errors.values
            .expand((value) => value is List ? value : <dynamic>[value])
            .map((value) => value.toString())
            .firstWhere((value) => value.trim().isNotEmpty, orElse: () => '');
        if (firstError.isNotEmpty) {
          return ApiError(firstError, statusCode: statusCode);
        }
      }
    }

    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.connectionError) {
      return const ApiError(
        'Sunucuya bağlanılamadı. API URL veya ağ bağlantısını kontrol edin.',
      );
    }

    return ApiError(
      'İstek başarısız oldu (${statusCode ?? 'n/a'}).',
      statusCode: statusCode,
    );
  }

  String _fullPath(String path) {
    return '$_baseUrl$path';
  }

  void _assertConfigured() {
    if (_baseUrl.trim().isEmpty) {
      throw const ApiError('API base URL ayarlanmamış.');
    }
  }

  Map<String, dynamic> _unwrapData(Map<String, dynamic> map) {
    final inner = map['data'];
    if (inner is Map<String, dynamic>) {
      return inner;
    }
    return map;
  }

  Map<String, dynamic> _expectMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    throw const ApiError('Sunucudan beklenmeyen bir veri yapısı döndü.');
  }
}
