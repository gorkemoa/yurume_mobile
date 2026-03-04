import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../models/models.dart';
import '../services/backend_api.dart';
import '../services/local_store.dart';
import 'auth_controller.dart';

class TrackingController extends ChangeNotifier {
  static const double _maxHumanSpeedMps = 4.2;
  static const double _speedSmoothAlpha = 0.35;
  static const double _duplicateDistanceFloorM = 1.8;
  static const double _duplicateDistanceCapM = 12;
  static const double _duplicateAccuracyFactor = 0.28;
  static const double _defaultAccuracyM = 8;
  static const double _maxTrustedAccuracyM = 55;
  static const double _minTrustedSpeedMps = 0.45;
  static const double _driftDistanceAccuracyRatio = 0.45;

  TrackingController({
    required BackendApi api,
    required AuthController authController,
    required LocalStore localStore,
  }) : _api = api,
       _authController = authController,
       _localStore = localStore {
    _authController.addListener(_onAuthChanged);
  }

  final BackendApi _api;
  final AuthController _authController;
  final LocalStore _localStore;

  bool _initialized = false;
  bool _initializing = false;
  bool _busyAction = false;
  String? _errorMessage;
  String _authFingerprint = '';

  MapConfig? _mapConfig;
  List<Territory> _territories = const <Territory>[];
  TrackingSession? _currentSession;
  Position? _currentPosition;
  List<RoutePoint> _liveRoutePoints = const <RoutePoint>[];
  final List<RoutePoint> _pendingPoints = <RoutePoint>[];
  StreamSubscription<Position>? _positionSubscription;
  Timer? _locationPulseTimer;
  Timer? _syncRetryTimer;
  Timer? _persistTimer;
  bool _flushing = false;
  bool _syncingPendingState = false;
  DateTime _lastFlushAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPositionEventAt = DateTime.fromMillisecondsSinceEpoch(0);
  double? _currentSpeedMps;
  double? _smoothedSpeedMps;
  bool _sessionNeedsStartSync = false;
  bool _pendingFinishSync = false;
  bool _pendingFinishClaimTerritory = true;
  String _pendingFinishOwnerVisibility = 'public';

  bool get initialized => _initialized;
  bool get busyAction => _busyAction;
  String? get errorMessage => _errorMessage;
  MapConfig? get mapConfig => _mapConfig;
  List<Territory> get territories => _territories;
  TrackingSession? get currentSession => _currentSession;
  Position? get currentPosition => _currentPosition;
  bool get isTracking =>
      !_pendingFinishSync && (_currentSession?.isActive ?? false);
  bool get hasPendingSync =>
      _sessionNeedsStartSync || _pendingFinishSync || _pendingPoints.isNotEmpty;
  int get pendingSyncPointCount => _pendingPoints.length;
  String? get syncStatus {
    if (_pendingFinishSync) {
      return 'Takip offline bitti. Internet gelince sunucuya işlenecek.';
    }
    if (_sessionNeedsStartSync) {
      return 'Offline takip aktif. Internet gelince otomatik yüklenecek.';
    }
    if (_pendingPoints.isNotEmpty) {
      return '${_pendingPoints.length} nokta senkron bekliyor.';
    }
    return null;
  }

  double? get currentSpeedMps => _currentSpeedMps;
  double? get currentSpeedKmh =>
      _currentSpeedMps == null ? null : _currentSpeedMps! * 3.6;
  double? get averageSpeedMps {
    final points = routePoints;
    final speeds = points
        .where((point) => point.speedMps != null && point.speedMps! >= 0)
        .map((point) => point.speedMps!)
        .toList(growable: false);

    if (speeds.isNotEmpty) {
      final sum = speeds.fold<double>(0, (acc, item) => acc + item);
      return sum / speeds.length;
    }

    if (points.length < 2) {
      return null;
    }

    final elapsedSeconds =
        points.last.recordedAt
            .difference(points.first.recordedAt)
            .inMilliseconds /
        1000;
    if (elapsedSeconds <= 0) {
      return null;
    }

    final distanceMeters = _totalDistanceMeters(points);
    return distanceMeters / elapsedSeconds;
  }

  double? get averageSpeedKmh =>
      averageSpeedMps == null ? null : averageSpeedMps! * 3.6;
  List<RoutePoint> get routePoints {
    if (_liveRoutePoints.isNotEmpty) {
      return _liveRoutePoints;
    }
    return _currentSession?.routePoints ?? const <RoutePoint>[];
  }

  Future<void> initialize() async {
    if (_initializing) {
      return;
    }
    _initializing = true;
    try {
      await _syncWithAuth(forceReload: true);
      _initialized = true;
    } finally {
      _initializing = false;
      notifyListeners();
    }
  }

  Future<void> refreshTerritories() async {
    if (!_authController.isAuthenticated) {
      return;
    }

    _configureApi();
    try {
      final items = await _api.listTerritories(perPage: 200);
      _territories = items;
      _clearError();
      notifyListeners();
    } catch (error) {
      if (_isRecoverableNetworkError(error)) {
        return;
      }
      _setError(error.toString());
    }
  }

  Future<void> startTracking() async {
    _assertAuthenticated();

    if (isTracking) {
      throw const ApiError('Zaten aktif bir takip oturumu var.');
    }
    if (hasPendingSync) {
      throw const ApiError(
        'Bekleyen offline verileriniz var. Internet gelince senkron tamamlanmalı.',
      );
    }

    await _withBusyAction(() async {
      await _ensureLocationPermission();
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
        ),
      );

      final startPoint = _buildRoutePoint(position);
      _currentPosition = position;
      try {
        _configureApi();
        final session = await _api.startTracking(startPoint: startPoint);
        _currentSession = session;
        _liveRoutePoints = session.routePoints;
        _pendingPoints.clear();
        _sessionNeedsStartSync = false;
        _pendingFinishSync = false;
        _clearError();
      } catch (error) {
        if (!_isRecoverableNetworkError(error)) {
          rethrow;
        }

        _currentSession = TrackingSession(
          id: 0,
          status: 'active',
          startPoint: GeoPoint(
            latitude: startPoint.latitude,
            longitude: startPoint.longitude,
          ),
          endPoint: GeoPoint(
            latitude: startPoint.latitude,
            longitude: startPoint.longitude,
          ),
          startedAt: startPoint.recordedAt,
          pointsCount: 1,
          routePoints: [startPoint],
        );
        _liveRoutePoints = [startPoint];
        _pendingPoints
          ..clear()
          ..add(startPoint);
        _sessionNeedsStartSync = true;
        _pendingFinishSync = false;
        _setError(
          'Internet yok. Takip offline baslatildi; baglanti gelince otomatik yüklenecek.',
        );
      }

      _currentSpeedMps = null;
      _smoothedSpeedMps = null;
      _schedulePersistTrackingState();
      _ensureSyncRetryTimer();
      unawaited(_syncPendingState());

      await _startPositionStream();
      notifyListeners();
    });
  }

  Future<FinishTrackingResult> finishTracking({
    bool claimTerritory = true,
    String ownerVisibility = 'public',
  }) async {
    _assertAuthenticated();

    final session = _currentSession;
    if (session == null || !session.isActive) {
      throw const ApiError('Bitirilecek aktif bir oturum bulunamadı.');
    }

    late FinishTrackingResult finishResult;

    await _withBusyAction(() async {
      while (_flushing || _syncingPendingState) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }

      final sessionId = session.id;
      if (sessionId > 0 && !_sessionNeedsStartSync) {
        final pending = List<RoutePoint>.from(_pendingPoints);
        _pendingPoints.clear();

        try {
          _configureApi();
          final result = await _api.finishTracking(
            sessionId: sessionId,
            claimTerritory: claimTerritory,
            ownerVisibility: ownerVisibility,
            points: pending,
          );
          finishResult = result;
          _currentSession = result.session;
          _liveRoutePoints = result.session.routePoints;
          _pendingFinishSync = false;
          _currentSpeedMps = null;
          _smoothedSpeedMps = null;
          _clearError();
          await refreshTerritories();
        } catch (error) {
          _pendingPoints.insertAll(0, pending);
          if (!_isRecoverableNetworkError(error)) {
            rethrow;
          }
          finishResult = _queueOfflineFinish(
            claimTerritory: claimTerritory,
            ownerVisibility: ownerVisibility,
            message:
                'Internet yok. Takip offline bitirildi; baglanti gelince sunucuya gönderilecek.',
          );
        }
      } else {
        finishResult = _queueOfflineFinish(
          claimTerritory: claimTerritory,
          ownerVisibility: ownerVisibility,
          message:
              'Takip offline bitirildi; internet gelince otomatik senkron edilecek.',
        );
      }

      _schedulePersistTrackingState();
      _ensureSyncRetryTimer();
      unawaited(_syncPendingState());
      notifyListeners();
    });

    return finishResult;
  }

  Future<void> forceRefreshSession() async {
    _assertAuthenticated();
    final session = _currentSession;
    if (session == null || session.id <= 0) {
      return;
    }

    _configureApi();
    final updated = await _api.getTrackingSession(sessionId: session.id);
    _currentSession = updated;
    if (_liveRoutePoints.isEmpty && updated.routePoints.isNotEmpty) {
      _liveRoutePoints = updated.routePoints;
    }
    notifyListeners();
  }

  Future<void> _syncWithAuth({bool forceReload = false}) async {
    final fingerprint =
        '${_authController.baseUrl}|${_authController.token ?? ''}';
    if (!forceReload && fingerprint == _authFingerprint) {
      return;
    }
    _authFingerprint = fingerprint;

    if (!_authController.isAuthenticated) {
      _clearStateForLoggedOutUser();
      return;
    }

    await _restoreTrackingState();
    _configureApi();
    _ensureSyncRetryTimer();
    await _loadMapConfig();
    await _loadCurrentPosition();
    await refreshTerritories();
    await _resumeActiveSession();
    await _startPositionStream();
    unawaited(_syncPendingState());
  }

  Future<void> _loadMapConfig() async {
    try {
      _mapConfig = await _api.getMapConfig();
      _clearError();
    } catch (error) {
      if (_isRecoverableNetworkError(error)) {
        return;
      }
      _setError(error.toString());
    }
  }

  Future<void> _loadCurrentPosition() async {
    try {
      await _ensureLocationPermission();
      _currentPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      _clearError();
    } catch (error) {
      _setError(error.toString());
    }
  }

  Future<void> _resumeActiveSession() async {
    try {
      final active = await _api.getActiveTrackingSession();
      if (active != null) {
        _currentSession = active;
        if (_liveRoutePoints.isEmpty && _pendingPoints.isEmpty) {
          _liveRoutePoints = active.routePoints;
        }
      } else if (!isTracking && !hasPendingSync) {
        _currentSession = null;
        _liveRoutePoints = const <RoutePoint>[];
      }
      _clearError();
      _schedulePersistTrackingState();
    } catch (error) {
      if (_isRecoverableNetworkError(error)) {
        return;
      }
      _setError(error.toString());
    }
  }

  Future<void> _startPositionStream() async {
    if (_positionSubscription != null) {
      return;
    }

    await _ensureLocationPermission();
    const settings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 1,
    );

    _positionSubscription =
        Geolocator.getPositionStream(locationSettings: settings).listen(
          (position) {
            _handlePositionUpdate(position);
          },
          onError: (Object error) {
            _setError('Konum akışı kesildi: $error');
            _positionSubscription?.cancel();
            _positionSubscription = null;
          },
          cancelOnError: false,
        );
    _ensureLocationPulseTimer();
  }

  void _handlePositionUpdate(Position position) {
    _currentPosition = position;
    _lastPositionEventAt = DateTime.now();

    if (!isTracking) {
      _currentSpeedMps = null;
      _smoothedSpeedMps = null;
      notifyListeners();
      return;
    }

    final previousPoint = _liveRoutePoints.isEmpty
        ? null
        : _liveRoutePoints.last;
    final point = _buildRoutePoint(position, previousPoint: previousPoint);
    if (_shouldIgnoreLowQualityDrift(point, previousPoint)) {
      notifyListeners();
      return;
    }

    if (_isDuplicatePoint(point)) {
      notifyListeners();
      return;
    }

    _liveRoutePoints = [..._liveRoutePoints, point];
    _pendingPoints.add(point);
    _syncSyntheticSessionToLiveRoute();
    _schedulePersistTrackingState();

    final now = DateTime.now();
    final dueByCount = _pendingPoints.length >= 10;
    final dueByTime =
        now.difference(_lastFlushAt) >= const Duration(seconds: 10);
    if (dueByCount || dueByTime) {
      unawaited(_flushPendingPoints());
    }
    if (_sessionNeedsStartSync) {
      unawaited(_syncPendingState());
    }

    notifyListeners();
  }

  bool _isDuplicatePoint(RoutePoint point) {
    if (_liveRoutePoints.isEmpty) {
      return false;
    }

    final last = _liveRoutePoints.last;
    final distance = Geolocator.distanceBetween(
      point.latitude,
      point.longitude,
      last.latitude,
      last.longitude,
    );
    final threshold = _duplicateThresholdM(last: last, candidate: point);
    return distance < threshold;
  }

  bool _shouldIgnoreLowQualityDrift(RoutePoint point, RoutePoint? previous) {
    if (previous == null) {
      return false;
    }

    final accuracyM = point.accuracyM ?? (_maxTrustedAccuracyM + 1);
    if (accuracyM <= _maxTrustedAccuracyM) {
      return false;
    }

    final speedMps = point.speedMps ?? 0;
    if (speedMps >= _minTrustedSpeedMps) {
      return false;
    }

    final distance = Geolocator.distanceBetween(
      point.latitude,
      point.longitude,
      previous.latitude,
      previous.longitude,
    );

    return distance < (accuracyM * _driftDistanceAccuracyRatio);
  }

  double _duplicateThresholdM({
    required RoutePoint last,
    required RoutePoint candidate,
  }) {
    final accuracyBased =
        math.max(_accuracyM(last), _accuracyM(candidate)) *
        _duplicateAccuracyFactor;
    return accuracyBased.clamp(
      _duplicateDistanceFloorM,
      _duplicateDistanceCapM,
    );
  }

  double _accuracyM(RoutePoint point) {
    final accuracy = point.accuracyM;
    if (accuracy == null || accuracy <= 0) {
      return _defaultAccuracyM;
    }
    return accuracy;
  }

  Future<void> _flushPendingPoints() async {
    if (_flushing || _pendingPoints.isEmpty || !isTracking) {
      return;
    }
    if (_sessionNeedsStartSync || _pendingFinishSync) {
      unawaited(_syncPendingState());
      return;
    }

    final sessionId = _currentSession?.id;
    if (sessionId == null || sessionId <= 0) {
      unawaited(_syncPendingState());
      return;
    }

    final sending = List<RoutePoint>.from(_pendingPoints);
    _pendingPoints.clear();

    _flushing = true;
    try {
      _configureApi();
      await _api.appendTrackingPoints(sessionId: sessionId, points: sending);
      _lastFlushAt = DateTime.now();
      _clearError();
      _schedulePersistTrackingState();
    } catch (error) {
      _pendingPoints.insertAll(0, sending);
      if (_isRecoverableNetworkError(error)) {
        _setError('Internet yok. Noktalar yerelde senkron bekliyor.');
      } else {
        _setError(error.toString());
      }
      _schedulePersistTrackingState();
    } finally {
      _flushing = false;
      notifyListeners();
    }
  }

  FinishTrackingResult _queueOfflineFinish({
    required bool claimTerritory,
    required String ownerVisibility,
    required String message,
  }) {
    _pendingFinishSync = true;
    _pendingFinishClaimTerritory = claimTerritory;
    _pendingFinishOwnerVisibility = ownerVisibility;
    _currentSpeedMps = null;
    _smoothedSpeedMps = null;
    _setError(message);

    final base = _currentSession;
    final startPoint = base?.startPoint ?? _firstRouteAsGeoPoint();
    final endPoint = _lastRouteAsGeoPoint();
    final sessionId = (base?.id ?? 0) <= 0 ? 0 : base!.id;

    final synthetic = TrackingSession(
      id: sessionId,
      status: 'finished_local_pending_sync',
      startPoint: startPoint,
      endPoint: endPoint,
      startedAt:
          base?.startedAt ??
          (_liveRoutePoints.isEmpty ? null : _liveRoutePoints.first.recordedAt),
      finishedAt: DateTime.now().toUtc(),
      pointsCount: _liveRoutePoints.length,
      routePoints: _liveRoutePoints,
    );
    _currentSession = synthetic;

    return FinishTrackingResult(
      session: synthetic,
      claimed: false,
      territory: null,
      message: message,
    );
  }

  Future<void> _syncPendingState() async {
    if (!_authController.isAuthenticated || _syncingPendingState) {
      return;
    }
    if (!hasPendingSync) {
      return;
    }

    _syncingPendingState = true;
    try {
      _configureApi();

      if (_sessionNeedsStartSync) {
        final startPoint = _resolveOfflineStartPoint();
        if (startPoint == null) {
          throw const ApiError(
            'Offline takip başlangıç noktası bulunamadı. Yeni bir takip başlatın.',
          );
        }

        final session = await _api.startTracking(startPoint: startPoint);
        _currentSession = session;
        _sessionNeedsStartSync = false;
        if (_pendingPoints.isNotEmpty &&
            _pointsAreNear(_pendingPoints.first, startPoint)) {
          _pendingPoints.removeAt(0);
        }
        _syncSyntheticSessionToLiveRoute();
      }

      final sessionId = _currentSession?.id;
      if (sessionId != null && sessionId > 0 && _pendingPoints.isNotEmpty) {
        final sending = List<RoutePoint>.from(_pendingPoints);
        _pendingPoints.clear();
        try {
          for (final chunk in _chunkRoutePoints(sending, 200)) {
            await _api.appendTrackingPoints(
              sessionId: sessionId,
              points: chunk,
            );
          }
          _lastFlushAt = DateTime.now();
        } catch (error) {
          _pendingPoints.insertAll(0, sending);
          rethrow;
        }
      }

      if (_pendingFinishSync) {
        final finishSessionId = _currentSession?.id;
        if (finishSessionId == null || finishSessionId <= 0) {
          return;
        }

        final result = await _api.finishTracking(
          sessionId: finishSessionId,
          claimTerritory: _pendingFinishClaimTerritory,
          ownerVisibility: _pendingFinishOwnerVisibility,
          points: const <RoutePoint>[],
        );

        _pendingFinishSync = false;
        _currentSession = result.session;
        _liveRoutePoints = result.session.routePoints;
        _currentSpeedMps = null;
        _smoothedSpeedMps = null;
        await refreshTerritories();
      }

      _clearError();
      _schedulePersistTrackingState();
    } catch (error) {
      if (!_isRecoverableNetworkError(error)) {
        _setError(error.toString());
      }
    } finally {
      _syncingPendingState = false;
      notifyListeners();
    }
  }

  void _ensureSyncRetryTimer() {
    if (_syncRetryTimer != null) {
      return;
    }
    _syncRetryTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (!hasPendingSync) {
        return;
      }
      unawaited(_syncPendingState());
    });
  }

  void _ensureLocationPulseTimer() {
    if (_locationPulseTimer != null) {
      return;
    }

    _locationPulseTimer = Timer.periodic(const Duration(seconds: 8), (_) async {
      if (!isTracking) {
        return;
      }

      final staleFor = DateTime.now().difference(_lastPositionEventAt);
      if (staleFor < const Duration(seconds: 9)) {
        return;
      }

      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.best,
          ),
        );
        _handlePositionUpdate(position);
      } catch (_) {
        // Passive fallback only; ignore transient pull failures.
      }
    });
  }

  void _schedulePersistTrackingState() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 550), () {
      unawaited(_persistTrackingState());
    });
  }

  Future<void> _persistTrackingState() async {
    if (!_shouldPersistTrackingState()) {
      await _localStore.clearTrackingState();
      return;
    }

    final data = <String, dynamic>{
      'v': 1,
      'session_needs_start_sync': _sessionNeedsStartSync,
      'pending_finish_sync': _pendingFinishSync,
      'pending_finish_claim_territory': _pendingFinishClaimTerritory,
      'pending_finish_owner_visibility': _pendingFinishOwnerVisibility,
      'current_session': _currentSession == null
          ? null
          : {
              'id': _currentSession!.id,
              'status': _currentSession!.status,
              'start_point': {
                'latitude': _currentSession!.startPoint.latitude,
                'longitude': _currentSession!.startPoint.longitude,
              },
              'end_point': _currentSession!.endPoint == null
                  ? null
                  : {
                      'latitude': _currentSession!.endPoint!.latitude,
                      'longitude': _currentSession!.endPoint!.longitude,
                    },
              'started_at': _currentSession!.startedAt?.toIso8601String(),
              'finished_at': _currentSession!.finishedAt?.toIso8601String(),
            },
      'live_route_points': _liveRoutePoints
          .map((point) => point.toApiJson())
          .toList(growable: false),
      'pending_points': _pendingPoints
          .map((point) => point.toApiJson())
          .toList(growable: false),
    };

    await _localStore.writeTrackingState(jsonEncode(data));
  }

  Future<void> _restoreTrackingState() async {
    final raw = _localStore.readTrackingState();
    if (raw == null || raw.trim().isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      final liveRaw = decoded['live_route_points'];
      final pendingRaw = decoded['pending_points'];
      _liveRoutePoints = _decodeRoutePoints(liveRaw);
      _pendingPoints
        ..clear()
        ..addAll(_decodeRoutePoints(pendingRaw));

      _sessionNeedsStartSync = decoded['session_needs_start_sync'] == true;
      _pendingFinishSync = decoded['pending_finish_sync'] == true;
      _pendingFinishClaimTerritory =
          decoded['pending_finish_claim_territory'] != false;
      _pendingFinishOwnerVisibility =
          (decoded['pending_finish_owner_visibility'] ?? 'public').toString();

      final sessionRaw = decoded['current_session'];
      if (sessionRaw is Map<String, dynamic>) {
        final sessionId = _toInt(sessionRaw['id']) ?? 0;
        final status = (sessionRaw['status'] ?? '').toString();
        final startRaw = sessionRaw['start_point'] as Map<String, dynamic>?;
        final endRaw = sessionRaw['end_point'] as Map<String, dynamic>?;
        final startPoint = startRaw == null
            ? (_liveRoutePoints.isNotEmpty
                  ? _firstRouteAsGeoPoint()
                  : const GeoPoint(latitude: 0, longitude: 0))
            : GeoPoint.fromJson(startRaw);

        _currentSession = TrackingSession(
          id: sessionId,
          status: status.isEmpty ? 'active' : status,
          startPoint: startPoint,
          endPoint: endRaw == null
              ? _lastRouteAsGeoPoint()
              : GeoPoint.fromJson(endRaw),
          startedAt: DateTime.tryParse(
            (sessionRaw['started_at'] ?? '').toString(),
          ),
          finishedAt: DateTime.tryParse(
            (sessionRaw['finished_at'] ?? '').toString(),
          ),
          pointsCount: _liveRoutePoints.length,
          routePoints: _liveRoutePoints,
        );
      } else if (_liveRoutePoints.isNotEmpty) {
        _currentSession = TrackingSession(
          id: 0,
          status: _pendingFinishSync ? 'finished_local_pending_sync' : 'active',
          startPoint: _firstRouteAsGeoPoint(),
          endPoint: _lastRouteAsGeoPoint(),
          startedAt: _liveRoutePoints.first.recordedAt,
          finishedAt: _pendingFinishSync ? DateTime.now().toUtc() : null,
          pointsCount: _liveRoutePoints.length,
          routePoints: _liveRoutePoints,
        );
      }
    } catch (_) {
      await _localStore.clearTrackingState();
    }
  }

  bool _shouldPersistTrackingState() {
    return isTracking || hasPendingSync;
  }

  RoutePoint? _resolveOfflineStartPoint() {
    if (_pendingPoints.isNotEmpty) {
      return _pendingPoints.first;
    }
    if (_liveRoutePoints.isNotEmpty) {
      return _liveRoutePoints.first;
    }
    return null;
  }

  void _syncSyntheticSessionToLiveRoute() {
    final session = _currentSession;
    if (session == null || session.id > 0 || _liveRoutePoints.isEmpty) {
      return;
    }

    _currentSession = TrackingSession(
      id: 0,
      status: session.status,
      startPoint: _firstRouteAsGeoPoint(),
      endPoint: _lastRouteAsGeoPoint(),
      startedAt: session.startedAt ?? _liveRoutePoints.first.recordedAt,
      finishedAt: session.finishedAt,
      pointsCount: _liveRoutePoints.length,
      routePoints: _liveRoutePoints,
    );
  }

  GeoPoint _firstRouteAsGeoPoint() {
    final first = _liveRoutePoints.first;
    return GeoPoint(latitude: first.latitude, longitude: first.longitude);
  }

  GeoPoint? _lastRouteAsGeoPoint() {
    if (_liveRoutePoints.isEmpty) {
      return null;
    }
    final last = _liveRoutePoints.last;
    return GeoPoint(latitude: last.latitude, longitude: last.longitude);
  }

  List<List<RoutePoint>> _chunkRoutePoints(List<RoutePoint> points, int size) {
    final chunks = <List<RoutePoint>>[];
    for (var i = 0; i < points.length; i += size) {
      final end = (i + size < points.length) ? i + size : points.length;
      chunks.add(points.sublist(i, end));
    }
    return chunks;
  }

  List<RoutePoint> _decodeRoutePoints(dynamic raw) {
    if (raw is! List) {
      return const <RoutePoint>[];
    }
    return raw
        .whereType<Map>()
        .map((item) => RoutePoint.fromJson(item.cast<String, dynamic>()))
        .toList(growable: false);
  }

  bool _pointsAreNear(RoutePoint a, RoutePoint b, {double thresholdM = 2.5}) {
    final distance = Geolocator.distanceBetween(
      a.latitude,
      a.longitude,
      b.latitude,
      b.longitude,
    );
    return distance <= thresholdM;
  }

  bool _isRecoverableNetworkError(Object error) {
    if (error is! ApiError) {
      return false;
    }
    if (error.statusCode == null) {
      return true;
    }
    final message = error.message.toLowerCase();
    return message.contains('bağlanılamadı') ||
        message.contains('baglanilamadi') ||
        message.contains('timeout') ||
        message.contains('connection') ||
        message.contains('socket');
  }

  int? _toInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  RoutePoint _buildRoutePoint(Position position, {RoutePoint? previousPoint}) {
    final candidateSpeed = _resolveSpeedMps(
      position: position,
      previousPoint: previousPoint,
    );
    final finalSpeed = _smoothSpeed(candidateSpeed);
    _currentSpeedMps = finalSpeed;

    return RoutePoint(
      latitude: position.latitude,
      longitude: position.longitude,
      recordedAt: position.timestamp.toUtc(),
      accuracyM: position.accuracy,
      speedMps: finalSpeed,
    );
  }

  double? _resolveSpeedMps({
    required Position position,
    required RoutePoint? previousPoint,
  }) {
    final sensorSpeed = _sanitizeSensorSpeed(
      speed: position.speed,
      accuracyM: position.accuracy,
    );
    final derivedSpeed = _deriveSpeedFromMovement(
      position: position,
      previousPoint: previousPoint,
    );

    if (sensorSpeed != null && derivedSpeed != null) {
      final delta = (sensorSpeed - derivedSpeed).abs();
      if (delta <= 1.4) {
        return (sensorSpeed + derivedSpeed) / 2;
      }
      return derivedSpeed;
    }

    return sensorSpeed ?? derivedSpeed;
  }

  double? _sanitizeSensorSpeed({
    required double speed,
    required double accuracyM,
  }) {
    if (speed < 0) {
      return null;
    }

    if (accuracyM > 35) {
      return null;
    }

    if (speed > _maxHumanSpeedMps) {
      return null;
    }

    return speed;
  }

  double? _deriveSpeedFromMovement({
    required Position position,
    required RoutePoint? previousPoint,
  }) {
    if (previousPoint == null) {
      return null;
    }

    final now = position.timestamp.toUtc();
    final elapsedSeconds =
        now.difference(previousPoint.recordedAt).inMilliseconds / 1000;
    if (elapsedSeconds <= 0.8 || elapsedSeconds > 30) {
      return null;
    }

    final distanceMeters = Geolocator.distanceBetween(
      previousPoint.latitude,
      previousPoint.longitude,
      position.latitude,
      position.longitude,
    );

    if (distanceMeters < 0.5) {
      return 0;
    }

    final calculated = distanceMeters / elapsedSeconds;
    if (calculated > _maxHumanSpeedMps) {
      return null;
    }

    return calculated;
  }

  double? _smoothSpeed(double? value) {
    if (value == null) {
      if (_smoothedSpeedMps == null) {
        return null;
      }

      _smoothedSpeedMps = (_smoothedSpeedMps! * 0.85).clamp(
        0,
        _maxHumanSpeedMps,
      );
      if (_smoothedSpeedMps! < 0.12) {
        _smoothedSpeedMps = 0;
      }
      return _smoothedSpeedMps;
    }

    if (_smoothedSpeedMps == null) {
      _smoothedSpeedMps = value.clamp(0, _maxHumanSpeedMps);
      return _smoothedSpeedMps;
    }

    _smoothedSpeedMps =
        (_smoothedSpeedMps! +
                ((value - _smoothedSpeedMps!) * _speedSmoothAlpha))
            .clamp(0, _maxHumanSpeedMps);
    return _smoothedSpeedMps;
  }

  double _totalDistanceMeters(List<RoutePoint> points) {
    var distance = 0.0;
    for (var i = 1; i < points.length; i++) {
      final prev = points[i - 1];
      final current = points[i];
      distance += Geolocator.distanceBetween(
        prev.latitude,
        prev.longitude,
        current.latitude,
        current.longitude,
      );
    }
    return distance;
  }

  Future<void> _ensureLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw const ApiError('Cihaz konum servisi kapalı. Lütfen konumu açın.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      throw const ApiError(
        'Konum izni kalıcı olarak reddedildi. Ayarlardan izin verin.',
      );
    }

    if (permission == LocationPermission.denied) {
      throw const ApiError('Konum izni olmadan rota takibi yapılamaz.');
    }
  }

  void _configureApi() {
    _api.configure(
      baseUrl: _authController.baseUrl,
      token: _authController.token,
    );
  }

  Future<void> _withBusyAction(Future<void> Function() action) async {
    if (_busyAction) {
      return;
    }

    _busyAction = true;
    notifyListeners();
    try {
      await action();
    } finally {
      _busyAction = false;
      notifyListeners();
    }
  }

  void _setError(String value) {
    final message = value.replaceFirst('ApiError: ', '').trim();
    if (message == _errorMessage || message.isEmpty) {
      return;
    }
    _errorMessage = message;
    notifyListeners();
  }

  void clearError() {
    _clearError();
    notifyListeners();
  }

  void _clearError() {
    _errorMessage = null;
  }

  void _assertAuthenticated() {
    if (!_authController.isAuthenticated) {
      throw const ApiError('Bu işlem için giriş yapmalısınız.');
    }
  }

  void _onAuthChanged() {
    unawaited(_syncWithAuth());
  }

  void _clearStateForLoggedOutUser() {
    _mapConfig = null;
    _territories = const <Territory>[];
    _currentSession = null;
    _liveRoutePoints = const <RoutePoint>[];
    _pendingPoints.clear();
    _sessionNeedsStartSync = false;
    _pendingFinishSync = false;
    _pendingFinishClaimTerritory = true;
    _pendingFinishOwnerVisibility = 'public';
    _flushing = false;
    _syncingPendingState = false;
    _currentPosition = null;
    _currentSpeedMps = null;
    _smoothedSpeedMps = null;
    _clearError();
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _locationPulseTimer?.cancel();
    _locationPulseTimer = null;
    _syncRetryTimer?.cancel();
    _syncRetryTimer = null;
    _persistTimer?.cancel();
    _persistTimer = null;
    unawaited(_localStore.clearTrackingState());
    notifyListeners();
  }

  @override
  void dispose() {
    _authController.removeListener(_onAuthChanged);
    _positionSubscription?.cancel();
    _locationPulseTimer?.cancel();
    _syncRetryTimer?.cancel();
    _persistTimer?.cancel();
    super.dispose();
  }
}
