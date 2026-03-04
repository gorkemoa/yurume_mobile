import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';

import '../models/models.dart';
import '../services/backend_api.dart';
import '../services/local_store.dart';

class AuthController extends ChangeNotifier {
  AuthController({required BackendApi api, required LocalStore localStore})
    : _api = api,
      _localStore = localStore;

  final BackendApi _api;
  final LocalStore _localStore;

  bool _initialized = false;
  bool _busy = false;
  String _baseUrl = _defaultApiBaseUrl();
  String _deviceName = 'flutter-device';
  String? _token;
  AppUser? _user;

  bool get initialized => _initialized;
  bool get busy => _busy;
  bool get isAuthenticated =>
      _token != null && _token!.isNotEmpty && _user != null;
  String get baseUrl => _baseUrl;
  String get deviceName => _deviceName;
  String? get token => _token;
  AppUser? get user => _user;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    _baseUrl = _normalizeBaseUrl(
      _localStore.readBaseUrl() ?? _defaultApiBaseUrl(),
    );
    _deviceName = _localStore.readDeviceName();
    _token = _localStore.readToken();
    _api.configure(baseUrl: _baseUrl, token: _token);

    if (_token != null && _token!.isNotEmpty) {
      try {
        _user = await _api.me();
      } catch (_) {
        _token = null;
        _user = null;
        await _localStore.clearToken();
        _api.configure(baseUrl: _baseUrl, token: null);
      }
    }

    _initialized = true;
    notifyListeners();
  }

  Future<void> setBaseUrl(String value) async {
    final normalized = _normalizeBaseUrl(value);
    _baseUrl = normalized;
    await _localStore.writeBaseUrl(normalized);
    _api.configure(baseUrl: _baseUrl, token: _token);
    notifyListeners();
  }

  Future<void> verifyBaseUrl(String value) async {
    final normalized = _normalizeBaseUrl(value);
    final ok = await _api.probeBaseUrl(normalized);
    if (!ok) {
      throw const ApiError(
        'Backend bulunamadı. Telefon ile backend aynı ağda olmalı ve backend 0.0.0.0:8000 üzerinde çalışmalı.',
      );
    }
  }

  Future<String> discoverLocalBackendBaseUrl() async {
    _setBusy(true);
    try {
      final candidates = await _buildCandidateBaseUrls();
      if (candidates.isEmpty) {
        throw const ApiError(
          'Yerel ağ IP bilgisi alınamadı. Wi-Fi bağlı olduğundan emin olun.',
        );
      }

      for (final chunk in _chunk(candidates, 24)) {
        final found = await _probeChunk(chunk);
        if (found != null) {
          await setBaseUrl(found);
          return found;
        }
      }

      throw const ApiError(
        'Backend otomatik bulunamadı. Bilgisayar IP adresini manuel girin (ör: http://192.168.1.34:8000/api).',
      );
    } finally {
      _setBusy(false);
    }
  }

  Future<void> setDeviceName(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return;
    }

    _deviceName = trimmed;
    await _localStore.writeDeviceName(trimmed);
    notifyListeners();
  }

  Future<void> login({
    required String email,
    required String password,
    String? deviceName,
  }) async {
    _setBusy(true);
    try {
      final result = await _api.login(
        email: email,
        password: password,
        deviceName: (deviceName == null || deviceName.trim().isEmpty)
            ? _deviceName
            : deviceName.trim(),
      );
      await _applyAuthResult(result);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> register({
    required String name,
    required String email,
    required String password,
    required String passwordConfirmation,
    String? deviceName,
  }) async {
    _setBusy(true);
    try {
      final result = await _api.register(
        name: name,
        email: email,
        password: password,
        passwordConfirmation: passwordConfirmation,
        deviceName: (deviceName == null || deviceName.trim().isEmpty)
            ? _deviceName
            : deviceName.trim(),
      );
      await _applyAuthResult(result);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> logout() async {
    _setBusy(true);
    try {
      if (_token != null && _token!.isNotEmpty) {
        try {
          await _api.logout();
        } catch (_) {
          // Session may already be invalidated on backend.
        }
      }
      await _clearSession();
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _applyAuthResult(AuthResult result) async {
    _token = result.token;
    _user = result.user;
    _api.configure(baseUrl: _baseUrl, token: _token);
    await _localStore.writeToken(result.token);
    notifyListeners();
  }

  Future<void> _clearSession() async {
    _token = null;
    _user = null;
    _api.configure(baseUrl: _baseUrl, token: null);
    await _localStore.clearToken();
    notifyListeners();
  }

  void _setBusy(bool value) {
    if (_busy == value) {
      return;
    }
    _busy = value;
    notifyListeners();
  }

  String _normalizeBaseUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const ApiError('API URL boş olamaz.');
    }

    final withScheme =
        trimmed.startsWith('http://') || trimmed.startsWith('https://')
        ? trimmed
        : 'http://$trimmed';

    var normalized = withScheme.replaceAll(RegExp(r'/+$'), '');
    if (!normalized.endsWith('/api')) {
      normalized = '$normalized/api';
    }
    return normalized;
  }

  Future<String?> _probeChunk(List<String> chunk) async {
    final futures = chunk.map((baseUrl) async {
      final ok = await _api.probeBaseUrl(baseUrl);
      return ok ? baseUrl : null;
    });
    final results = await Future.wait(futures);
    for (final item in results) {
      if (item != null) {
        return item;
      }
    }
    return null;
  }

  Future<List<String>> _buildCandidateBaseUrls() async {
    final networkInfo = NetworkInfo();
    final wifiIp = await networkInfo.getWifiIP();
    final gatewayIp = await networkInfo.getWifiGatewayIP();

    final candidates = <String>{};

    final persistedHost = _extractHost(_baseUrl);
    if (persistedHost != null) {
      candidates.add('http://$persistedHost:8000/api');
    }

    if (gatewayIp != null && gatewayIp.trim().isNotEmpty) {
      candidates.add('http://${gatewayIp.trim()}:8000/api');
    }

    if (wifiIp == null || wifiIp.trim().isEmpty) {
      return candidates.toList(growable: false);
    }

    final octets = wifiIp.trim().split('.');
    if (octets.length != 4) {
      return candidates.toList(growable: false);
    }

    final prefix = '${octets[0]}.${octets[1]}.${octets[2]}';
    final current = int.tryParse(octets[3]) ?? 0;
    final gatewayLast = gatewayIp != null
        ? int.tryParse(gatewayIp.split('.').last)
        : null;

    void addHost(int last) {
      if (last <= 1 || last >= 255) {
        return;
      }
      if (last == current || last == gatewayLast) {
        return;
      }
      candidates.add('http://$prefix.$last:8000/api');
    }

    for (var i = 2; i <= 80; i++) {
      addHost(i);
    }

    for (var i = current - 30; i <= current + 30; i++) {
      addHost(i);
    }

    for (var i = 81; i <= 254; i++) {
      addHost(i);
    }

    return candidates.toList(growable: false);
  }

  List<List<String>> _chunk(List<String> source, int size) {
    final chunks = <List<String>>[];
    for (var i = 0; i < source.length; i += size) {
      final end = (i + size < source.length) ? i + size : source.length;
      chunks.add(source.sublist(i, end));
    }
    return chunks;
  }

  String? _extractHost(String url) {
    final uri = Uri.tryParse(url);
    final host = uri?.host.trim();
    if (host == null || host.isEmpty) {
      return null;
    }
    return host;
  }
}

String _defaultApiBaseUrl() {
  if (kIsWeb) {
    return 'http://localhost:8000/api';
  }

  if (Platform.isAndroid) {
    return 'http://10.0.2.2:8000/api';
  }

  return 'http://127.0.0.1:8000/api';
}
