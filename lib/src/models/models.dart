class AppUser {
  const AppUser({required this.id, required this.name, this.email});

  final int id;
  final String name;
  final String? email;

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: _asInt(json['id']) ?? 0,
      name: (json['name'] ?? '').toString(),
      email: json['email']?.toString(),
    );
  }
}

class GeoPoint {
  const GeoPoint({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;

  factory GeoPoint.fromJson(Map<String, dynamic> json) {
    return GeoPoint(
      latitude: _asDouble(json['latitude'] ?? json['lat']) ?? 0,
      longitude: _asDouble(json['longitude'] ?? json['lng']) ?? 0,
    );
  }

  Map<String, dynamic> toApiJson() {
    return {'latitude': latitude, 'longitude': longitude};
  }
}

class RoutePoint extends GeoPoint {
  const RoutePoint({
    required super.latitude,
    required super.longitude,
    required this.recordedAt,
    this.sequence,
    this.accuracyM,
    this.speedMps,
  });

  final DateTime recordedAt;
  final int? sequence;
  final double? accuracyM;
  final double? speedMps;

  factory RoutePoint.fromJson(Map<String, dynamic> json) {
    return RoutePoint(
      sequence: _asInt(json['sequence']),
      latitude: _asDouble(json['latitude'] ?? json['lat']) ?? 0,
      longitude: _asDouble(json['longitude'] ?? json['lng']) ?? 0,
      recordedAt:
          DateTime.tryParse((json['recorded_at'] ?? '').toString()) ??
          DateTime.now().toUtc(),
      accuracyM: _asDouble(json['accuracy_m']),
      speedMps: _asDouble(json['speed_mps']),
    );
  }

  @override
  Map<String, dynamic> toApiJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'recorded_at': recordedAt.toUtc().toIso8601String(),
      if (accuracyM != null) 'accuracy_m': accuracyM,
      if (speedMps != null) 'speed_mps': speedMps,
    };
  }
}

class TrackingSession {
  const TrackingSession({
    required this.id,
    required this.status,
    required this.startPoint,
    this.endPoint,
    this.startedAt,
    this.finishedAt,
    this.closureType,
    this.closureDistanceM,
    this.pointsCount = 0,
    this.routePoints = const [],
    this.territory,
  });

  final int id;
  final String status;
  final GeoPoint startPoint;
  final GeoPoint? endPoint;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final String? closureType;
  final double? closureDistanceM;
  final int pointsCount;
  final List<RoutePoint> routePoints;
  final Territory? territory;

  bool get isActive => status == 'active';

  factory TrackingSession.fromJson(Map<String, dynamic> json) {
    final routePointsRaw = json['route_points'];
    final points = routePointsRaw is List
        ? routePointsRaw
              .whereType<Map<String, dynamic>>()
              .map(RoutePoint.fromJson)
              .toList(growable: false)
        : const <RoutePoint>[];

    return TrackingSession(
      id: _asInt(json['id']) ?? 0,
      status: (json['status'] ?? '').toString(),
      startPoint: GeoPoint.fromJson(
        (json['start_point'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      ),
      endPoint: json['end_point'] is Map<String, dynamic>
          ? GeoPoint.fromJson(json['end_point'] as Map<String, dynamic>)
          : null,
      startedAt: DateTime.tryParse((json['started_at'] ?? '').toString()),
      finishedAt: DateTime.tryParse((json['finished_at'] ?? '').toString()),
      closureType: json['closure_type']?.toString(),
      closureDistanceM: _asDouble(json['closure_distance_m']),
      pointsCount: _asInt(json['points_count']) ?? points.length,
      routePoints: points,
      territory: json['territory'] is Map<String, dynamic>
          ? Territory.fromJson(json['territory'] as Map<String, dynamic>)
          : null,
    );
  }
}

class TerritoryBounds {
  const TerritoryBounds({
    required this.minLat,
    required this.maxLat,
    required this.minLng,
    required this.maxLng,
  });

  final double minLat;
  final double maxLat;
  final double minLng;
  final double maxLng;

  factory TerritoryBounds.fromJson(Map<String, dynamic> json) {
    return TerritoryBounds(
      minLat: _asDouble(json['min_lat']) ?? 0,
      maxLat: _asDouble(json['max_lat']) ?? 0,
      minLng: _asDouble(json['min_lng']) ?? 0,
      maxLng: _asDouble(json['max_lng']) ?? 0,
    );
  }
}

class Territory {
  const Territory({
    required this.id,
    required this.userId,
    required this.trackingSessionId,
    required this.ownerVisibility,
    required this.shapeType,
    required this.closureType,
    required this.areaM2,
    required this.perimeterM,
    required this.centroid,
    required this.bounds,
    required this.polygonPoints,
    required this.acquiredAt,
    required this.ownerDisplayName,
    required this.ownerIsAnonymous,
    required this.ownerIsOwner,
  });

  final int id;
  final int userId;
  final int trackingSessionId;
  final String ownerVisibility;
  final String shapeType;
  final String closureType;
  final double areaM2;
  final double perimeterM;
  final GeoPoint centroid;
  final TerritoryBounds bounds;
  final List<GeoPoint> polygonPoints;
  final DateTime acquiredAt;
  final String ownerDisplayName;
  final bool ownerIsAnonymous;
  final bool ownerIsOwner;

  factory Territory.fromJson(Map<String, dynamic> json) {
    final polygonRaw = json['polygon_points'];
    final polygon = polygonRaw is List
        ? polygonRaw
              .whereType<Map<String, dynamic>>()
              .map(GeoPoint.fromJson)
              .toList(growable: false)
        : const <GeoPoint>[];

    return Territory(
      id: _asInt(json['id']) ?? 0,
      userId: _asInt(json['user_id']) ?? 0,
      trackingSessionId: _asInt(json['tracking_session_id']) ?? 0,
      ownerVisibility: (json['owner_visibility'] ?? 'public').toString(),
      shapeType: (json['shape_type'] ?? '').toString(),
      closureType: (json['closure_type'] ?? '').toString(),
      areaM2: _asDouble(json['area_m2']) ?? 0,
      perimeterM: _asDouble(json['perimeter_m']) ?? 0,
      centroid: GeoPoint.fromJson(
        (json['centroid'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      ),
      bounds: TerritoryBounds.fromJson(
        (json['bounds'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      ),
      polygonPoints: polygon,
      acquiredAt:
          DateTime.tryParse((json['acquired_at'] ?? '').toString()) ??
          DateTime.now().toUtc(),
      ownerDisplayName:
          (json['owner'] as Map?)?['display_name']?.toString() ??
          (json['owner'] as Map?)?['name']?.toString() ??
          'Bilinmiyor',
      ownerIsAnonymous: (json['owner'] as Map?)?['is_anonymous'] == true,
      ownerIsOwner: (json['owner'] as Map?)?['is_owner'] == true,
    );
  }
}

class MapTilesConfig {
  const MapTilesConfig({
    required this.url,
    required this.attribution,
    required this.minZoom,
    required this.maxZoom,
    required this.subdomains,
  });

  final String url;
  final String attribution;
  final int minZoom;
  final int maxZoom;
  final List<String> subdomains;

  factory MapTilesConfig.fromJson(Map<String, dynamic> json) {
    final subdomains =
        (json['subdomains'] as List?)
            ?.map((value) => value.toString())
            .toList(growable: false) ??
        const <String>[];

    return MapTilesConfig(
      url: (json['url'] ?? '').toString(),
      attribution: (json['attribution'] ?? '').toString(),
      minZoom: _asInt(json['min_zoom']) ?? 0,
      maxZoom: _asInt(json['max_zoom']) ?? 19,
      subdomains: subdomains,
    );
  }
}

class MapConfig {
  const MapConfig({
    required this.provider,
    required this.tiles,
    required this.policyUrl,
  });

  final String provider;
  final MapTilesConfig tiles;
  final String policyUrl;

  factory MapConfig.fromJson(Map<String, dynamic> json) {
    return MapConfig(
      provider: (json['provider'] ?? '').toString(),
      tiles: MapTilesConfig.fromJson(
        (json['tiles'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      ),
      policyUrl: (json['policy_url'] ?? '').toString(),
    );
  }
}

class AuthResult {
  const AuthResult({required this.token, required this.user});

  final String token;
  final AppUser user;

  factory AuthResult.fromJson(Map<String, dynamic> json) {
    return AuthResult(
      token: (json['token'] ?? '').toString(),
      user: AppUser.fromJson(
        (json['user'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      ),
    );
  }
}

class FinishTrackingResult {
  const FinishTrackingResult({
    required this.session,
    required this.claimed,
    this.territory,
    this.message,
  });

  final TrackingSession session;
  final bool claimed;
  final Territory? territory;
  final String? message;
}

class ApiError implements Exception {
  const ApiError(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

double? _asDouble(dynamic value) {
  if (value is num) {
    return value.toDouble();
  }

  if (value is String) {
    return double.tryParse(value);
  }

  return null;
}

int? _asInt(dynamic value) {
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
