import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

class LocalStore {
  const LocalStore(this._preferences);

  final SharedPreferences _preferences;

  static const _tokenKey = 'auth_token';
  static const _authUserKey = 'auth_user_json';
  static const _baseUrlKey = 'api_base_url';
  static const _deviceNameKey = 'device_name';
  static const _trackingStateKey = 'tracking_sync_state_v1';

  String? readToken() => _preferences.getString(_tokenKey);

  Future<void> writeToken(String token) async {
    await _preferences.setString(_tokenKey, token);
  }

  Future<void> clearToken() async {
    await _preferences.remove(_tokenKey);
  }

  String? readAuthUserJson() => _preferences.getString(_authUserKey);

  Future<void> writeAuthUserJson(String userJson) async {
    await _preferences.setString(_authUserKey, userJson);
  }

  Future<void> clearAuthUserJson() async {
    await _preferences.remove(_authUserKey);
  }

  String? readBaseUrl() => _preferences.getString(_baseUrlKey);

  Future<void> writeBaseUrl(String value) async {
    await _preferences.setString(_baseUrlKey, value);
  }

  String readDeviceName() {
    final existing = _preferences.getString(_deviceNameKey);
    if (existing != null && existing.trim().isNotEmpty) {
      return existing;
    }

    if (Platform.isAndroid) {
      return 'flutter-android';
    }

    if (Platform.isIOS) {
      return 'flutter-ios';
    }

    return 'flutter-device';
  }

  Future<void> writeDeviceName(String value) async {
    await _preferences.setString(_deviceNameKey, value);
  }

  String? readTrackingState() => _preferences.getString(_trackingStateKey);

  Future<void> writeTrackingState(String value) async {
    await _preferences.setString(_trackingStateKey, value);
  }

  Future<void> clearTrackingState() async {
    await _preferences.remove(_trackingStateKey);
  }
}
