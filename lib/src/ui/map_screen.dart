import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'dart:math' as math;

import '../controllers/auth_controller.dart';
import '../controllers/tracking_controller.dart';
import '../models/models.dart';
import 'settings_bottom_sheet.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  static const _fallbackTiles = MapTilesConfig(
    url: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    attribution: '(c) OpenStreetMap contributors',
    minZoom: 0,
    maxZoom: 19,
    subdomains: <String>[],
  );

  final MapController _mapController = MapController();
  bool _didAutoCenter = false;
  int? _selectedTerritoryId;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final tracking = context.watch<TrackingController>();

    final tiles = tracking.mapConfig?.tiles ?? _fallbackTiles;
    final center = _initialCenter(
      tracking.currentPosition,
      tracking.routePoints,
    );
    final routePoints = tracking.routePoints
        .map((point) => LatLng(point.latitude, point.longitude))
        .toList(growable: false);
    final territories = tracking.territories;

    _tryAutoCenter(center);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Yurume Harita'),
        actions: [
          IconButton(
            onPressed: () => tracking.refreshTerritories(),
            icon: const Icon(Icons.sync),
            tooltip: 'Alanları yenile',
          ),
          IconButton(
            onPressed: () => _openSettings(context, auth, tracking),
            icon: const Icon(Icons.settings),
            tooltip: 'Ayarlar',
          ),
          IconButton(
            onPressed: auth.busy ? null : () => auth.logout(),
            icon: const Icon(Icons.logout),
            tooltip: 'Çıkış',
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: 16,
              maxZoom: tiles.maxZoom.toDouble(),
              minZoom: tiles.minZoom.toDouble(),
              onTap: (tapPosition, point) {
                if (_selectedTerritoryId != null) {
                  setState(() => _selectedTerritoryId = null);
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: tiles.url,
                userAgentPackageName: 'com.yurume.mobile',
                maxZoom: tiles.maxZoom.toDouble(),
                minZoom: tiles.minZoom.toDouble(),
                subdomains: tiles.subdomains,
              ),
              PolygonLayer(
                polygons: _buildTerritoryPolygons(
                  territories: territories,
                  currentUserId: auth.user?.id,
                ),
              ),
              if (routePoints.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: routePoints,
                      color: Colors.redAccent,
                      strokeWidth: 5,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: _buildMarkers(
                  currentPosition: tracking.currentPosition,
                  session: tracking.currentSession,
                  territories: territories,
                  currentUserId: auth.user?.id,
                ),
              ),
              RichAttributionWidget(
                popupBackgroundColor: Colors.white.withValues(alpha: 0.95),
                attributions: [TextSourceAttribution(tiles.attribution)],
              ),
            ],
          ),
          Positioned(
            top: 14,
            left: 14,
            right: 14,
            child: _TopStatusCard(
              username: auth.user?.name ?? '',
              isTracking: tracking.isTracking,
              pointsCount: routePoints.length,
              territoryCount: territories.length,
              totalAreaM2: territories.fold<double>(
                0,
                (sum, territory) => sum + territory.areaM2,
              ),
              currentSpeedKmh: tracking.currentSpeedKmh,
              averageSpeedKmh: tracking.averageSpeedKmh,
              busyAction: tracking.busyAction,
              syncStatus: tracking.syncStatus,
            ),
          ),
          if (tracking.errorMessage != null &&
              tracking.errorMessage!.trim().isNotEmpty)
            Positioned(
              left: 14,
              right: 14,
              top: 126,
              child: Material(
                elevation: 2,
                borderRadius: BorderRadius.circular(12),
                color: Colors.red.shade50,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: Colors.red.shade700),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          tracking.errorMessage!,
                          style: TextStyle(color: Colors.red.shade900),
                        ),
                      ),
                      IconButton(
                        onPressed: tracking.clearError,
                        icon: const Icon(Icons.close),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: tracking.isTracking
                      ? Colors.red
                      : Colors.green,
                ),
                onPressed: tracking.busyAction
                    ? null
                    : () => _handleTrackButtonPressed(context, tracking),
                icon: Icon(tracking.isTracking ? Icons.stop : Icons.play_arrow),
                label: Text(tracking.isTracking ? 'Bitir' : 'Başlat'),
              ),
            ),
            const SizedBox(width: 8),
            if (tracking.isTracking) ...[
              IconButton.filledTonal(
                onPressed: tracking.busyAction
                    ? null
                    : () => _handleAbandonPressed(context, tracking),
                icon: const Icon(Icons.close),
                tooltip: 'Vazgeç (alan kaydetme)',
              ),
              const SizedBox(width: 8),
            ],
            IconButton.filledTonal(
              onPressed: tracking.busyAction
                  ? null
                  : () => _recenter(tracking.currentPosition),
              icon: const Icon(Icons.my_location),
              tooltip: 'Konuma git',
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: tracking.busyAction
                  ? null
                  : () => tracking.refreshTerritories(),
              icon: const Icon(Icons.layers),
              tooltip: 'Alanları yenile',
            ),
          ],
        ),
      ),
    );
  }

  void _tryAutoCenter(LatLng center) {
    if (_didAutoCenter) {
      return;
    }
    _didAutoCenter = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapController.move(center, 16);
    });
  }

  LatLng _initialCenter(
    Position? currentPosition,
    List<RoutePoint> routePoints,
  ) {
    if (currentPosition != null) {
      return LatLng(currentPosition.latitude, currentPosition.longitude);
    }

    if (routePoints.isNotEmpty) {
      final first = routePoints.first;
      return LatLng(first.latitude, first.longitude);
    }

    return const LatLng(41.0082, 28.9784);
  }

  List<Polygon> _buildTerritoryPolygons({
    required List<Territory> territories,
    required int? currentUserId,
  }) {
    return territories
        .where((territory) => territory.polygonPoints.length >= 3)
        .map((territory) {
          final points = territory.polygonPoints
              .map((point) => LatLng(point.latitude, point.longitude))
              .toList(growable: false);

          final fillColor = _territoryFillColor(territory, currentUserId);
          return Polygon(
            points: points,
            color: fillColor,
            borderColor: fillColor.withValues(alpha: 1),
            borderStrokeWidth: 2,
          );
        })
        .toList(growable: false);
  }

  List<Marker> _buildMarkers({
    required Position? currentPosition,
    required TrackingSession? session,
    required List<Territory> territories,
    required int? currentUserId,
  }) {
    final markers = <Marker>[];
    if (currentPosition != null) {
      markers.add(
        Marker(
          point: LatLng(currentPosition.latitude, currentPosition.longitude),
          width: 22,
          height: 22,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.blueAccent,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (session != null) {
      markers.add(
        Marker(
          point: LatLng(
            session.startPoint.latitude,
            session.startPoint.longitude,
          ),
          width: 34,
          height: 34,
          child: const Icon(Icons.flag, color: Colors.green, size: 28),
        ),
      );

      if (session.endPoint != null) {
        markers.add(
          Marker(
            point: LatLng(
              session.endPoint!.latitude,
              session.endPoint!.longitude,
            ),
            width: 34,
            height: 34,
            child: const Icon(Icons.flag, color: Colors.red, size: 28),
          ),
        );
      }
    }

    for (final territory in territories) {
      final centroid = _territoryPinPoint(territory);
      final selected = _selectedTerritoryId == territory.id;
      final pinColor = _territoryPinColor(territory, currentUserId);

      markers.add(
        Marker(
          point: centroid,
          width: 38,
          height: 38,
          child: GestureDetector(
            onTap: () {
              setState(() {
                _selectedTerritoryId = selected ? null : territory.id;
              });
            },
            child: Icon(
              selected ? Icons.location_pin : Icons.location_on,
              color: pinColor,
              size: selected ? 36 : 30,
            ),
          ),
        ),
      );

      if (selected) {
        markers.add(_buildTerritoryInfoBubble(territory));
      }
    }

    return markers;
  }

  Marker _buildTerritoryInfoBubble(Territory territory) {
    final pinPoint = _territoryPinPoint(territory);
    final acquiredAt = territory.acquiredAt.toLocal();
    final dateLabel =
        '${acquiredAt.day.toString().padLeft(2, '0')}.'
        '${acquiredAt.month.toString().padLeft(2, '0')}.'
        '${acquiredAt.year} '
        '${acquiredAt.hour.toString().padLeft(2, '0')}:'
        '${acquiredAt.minute.toString().padLeft(2, '0')}';
    final ownerLabel = territory.ownerDisplayName;

    return Marker(
      point: pinPoint,
      width: 230,
      height: 150,
      child: Transform.translate(
        offset: const Offset(0, -88),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.97),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.black12),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: DefaultTextStyle(
                style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 12.5,
                  height: 1.25,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ownerLabel,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text('Alan: ${territory.areaM2.toStringAsFixed(1)} m2'),
                    Text(
                      'Gorunurluk: ${territory.ownerVisibility == 'anonymous' ? 'Anonim' : 'Public'}',
                    ),
                    Text('Alindi: $dateLabel'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 2),
            const Icon(Icons.arrow_drop_down, color: Colors.black54, size: 22),
          ],
        ),
      ),
    );
  }

  LatLng _territoryPinPoint(Territory territory) {
    final polygon = territory.polygonPoints;
    if (polygon.length < 3) {
      return LatLng(territory.centroid.latitude, territory.centroid.longitude);
    }

    final latRefRad =
        polygon.map((point) => point.latitude).reduce((a, b) => a + b) /
        polygon.length *
        (math.pi / 180);
    final originLatRad = polygon.first.latitude * (math.pi / 180);
    final originLngRad = polygon.first.longitude * (math.pi / 180);
    final cosRef = math.cos(latRefRad).abs() < 1.0e-9
        ? 1.0e-9
        : math.cos(latRefRad);
    const earthRadiusM = 6371008.8;

    final points = [...polygon, polygon.first];
    double crossSum = 0;
    double crossCentroidX = 0;
    double crossCentroidY = 0;

    for (var i = 0; i < points.length - 1; i++) {
      final aLatRad = points[i].latitude * (math.pi / 180);
      final aLngRad = points[i].longitude * (math.pi / 180);
      final bLatRad = points[i + 1].latitude * (math.pi / 180);
      final bLngRad = points[i + 1].longitude * (math.pi / 180);

      final ax = (aLngRad - originLngRad) * earthRadiusM * cosRef;
      final ay = (aLatRad - originLatRad) * earthRadiusM;
      final bx = (bLngRad - originLngRad) * earthRadiusM * cosRef;
      final by = (bLatRad - originLatRad) * earthRadiusM;
      final cross = (ax * by) - (bx * ay);

      crossSum += cross;
      crossCentroidX += (ax + bx) * cross;
      crossCentroidY += (ay + by) * cross;
    }

    if (crossSum.abs() <= 1.0e-9) {
      return LatLng(territory.centroid.latitude, territory.centroid.longitude);
    }

    final centroidX = crossCentroidX / (3 * crossSum);
    final centroidY = crossCentroidY / (3 * crossSum);
    final lat = (originLatRad + (centroidY / earthRadiusM)) * (180 / math.pi);
    final lng =
        (originLngRad + (centroidX / (earthRadiusM * cosRef))) *
        (180 / math.pi);
    return LatLng(lat, lng);
  }

  Future<void> _handleTrackButtonPressed(
    BuildContext context,
    TrackingController tracking,
  ) async {
    try {
      if (tracking.isTracking) {
        final ownerVisibility = await _askOwnerVisibility(context);
        if (ownerVisibility == null) {
          return;
        }

        final result = await tracking.finishTracking(
          ownerVisibility: ownerVisibility,
        );
        if (context.mounted) {
          final message = result.claimed
              ? 'Alan başarıyla kaydedildi.'
              : (result.message ?? 'Takip bitirildi. Alan kaydedilmedi.');
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
      } else {
        await tracking.startTracking();
        if (context.mounted) {
          final info = tracking.syncStatus;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(info ?? 'Takip başlatıldı.')));
        }
      }
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ),
      );
    }
  }

  Future<void> _handleAbandonPressed(
    BuildContext context,
    TrackingController tracking,
  ) async {
    final shouldClose = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Takibi Bitir'),
          content: const Text(
            'Bu oturum kapatılsın ama alan kaydedilmesin mi?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('İptal'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Evet, Kaydetme'),
            ),
          ],
        );
      },
    );

    if (shouldClose != true) {
      return;
    }

    try {
      final result = await tracking.finishTracking(claimTerritory: false);
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.message ?? 'Takip bitirildi. Alan kaydedilmedi.',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ),
      );
    }
  }

  Future<void> _openSettings(
    BuildContext context,
    AuthController auth,
    TrackingController tracking,
  ) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SettingsBottomSheet(
          initialBaseUrl: auth.baseUrl,
          initialDeviceName: auth.deviceName,
          onSave: (baseUrl, deviceName) async {
            await auth.setBaseUrl(baseUrl);
            await auth.setDeviceName(deviceName);
            await tracking.initialize();
          },
        );
      },
    );

    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Ayarlar kaydedildi.')));
    }
  }

  void _recenter(Position? currentPosition) {
    if (currentPosition == null) {
      return;
    }
    _mapController.move(
      LatLng(currentPosition.latitude, currentPosition.longitude),
      17,
    );
  }

  Future<String?> _askOwnerVisibility(BuildContext context) async {
    var selected = 'public';

    return showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Alan Sahipligi'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      selected == 'public'
                          ? Icons.check_circle
                          : Icons.circle_outlined,
                      color: selected == 'public'
                          ? Colors.green
                          : Colors.black45,
                    ),
                    title: const Text('Public (ismini goster)'),
                    onTap: () => setState(() => selected = 'public'),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      selected == 'anonymous'
                          ? Icons.check_circle
                          : Icons.circle_outlined,
                      color: selected == 'anonymous'
                          ? Colors.green
                          : Colors.black45,
                    ),
                    title: const Text('Anonim (ismini gizle)'),
                    onTap: () => setState(() => selected = 'anonymous'),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Iptal'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(selected),
                  child: const Text('Bitir ve Kaydet'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Color _territoryFillColor(Territory territory, int? currentUserId) {
    if (currentUserId != null && territory.userId == currentUserId) {
      return Colors.green.withValues(alpha: 0.30);
    }

    final seed = territory.id + territory.userId * 31;
    final red = 90 + (seed * 37) % 130;
    final green = 70 + (seed * 67) % 130;
    final blue = 70 + (seed * 17) % 130;
    return Color.fromRGBO(red, green, blue, 0.26);
  }

  Color _territoryPinColor(Territory territory, int? currentUserId) {
    if (currentUserId != null && territory.userId == currentUserId) {
      return Colors.green.shade700;
    }
    if (territory.ownerIsAnonymous) {
      return Colors.blueGrey.shade700;
    }
    return Colors.deepOrange.shade700;
  }
}

class _TopStatusCard extends StatelessWidget {
  const _TopStatusCard({
    required this.username,
    required this.isTracking,
    required this.pointsCount,
    required this.territoryCount,
    required this.totalAreaM2,
    required this.currentSpeedKmh,
    required this.averageSpeedKmh,
    required this.busyAction,
    required this.syncStatus,
  });

  final String username;
  final bool isTracking;
  final int pointsCount;
  final int territoryCount;
  final double totalAreaM2;
  final double? currentSpeedKmh;
  final double? averageSpeedKmh;
  final bool busyAction;
  final String? syncStatus;

  @override
  Widget build(BuildContext context) {
    final statusColor = isTracking ? Colors.red : Colors.green;
    final statusLabel = isTracking ? 'Takip aktif' : 'Takip pasif';

    return Material(
      borderRadius: BorderRadius.circular(12),
      color: Colors.white.withValues(alpha: 0.92),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(username, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.circle, size: 10, color: statusColor),
                const SizedBox(width: 6),
                Text(statusLabel),
                if (busyAction) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text('Rota noktası: $pointsCount'),
            Text('Anlık hız: ${_speedLabel(currentSpeedKmh)} km/h'),
            Text('Ortalama hız: ${_speedLabel(averageSpeedKmh)} km/h'),
            Text('Sahip olunan alan: $territoryCount'),
            Text('Toplam alan: ${totalAreaM2.toStringAsFixed(1)} m2'),
            if (syncStatus != null) ...[
              const SizedBox(height: 4),
              Text(
                syncStatus!,
                style: TextStyle(
                  color: Colors.orange.shade800,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _speedLabel(double? value) {
    if (value == null) {
      return '-';
    }
    return value.toStringAsFixed(2);
  }
}
