import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui; // NEW: Used to draw custom passenger numbers!
import 'package:flutter/material.dart';
import 'route_data.dart';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:stomp_dart_client/stomp_dart_client.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class MapScreen extends StatefulWidget {
  final int busId;
  final int routeId;
  final String directionTitle;
  final String startLocationName;
  final String endLocationName;

  const MapScreen({
    super.key,
    required this.busId,
    required this.routeId,
    required this.directionTitle,
    required this.startLocationName,
    required this.endLocationName,
  });

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? _mapController;
  Set<Polyline> _polylines = {};

  // Set initial camera to the new starting point
  static const CameraPosition _initialPosition = CameraPosition(
    target: LatLng(6.91125032, 79.88253926),
    zoom: 14.5,
  );

  final String _mapStyle = '''
  [
    { "featureType": "poi", "elementType": "labels", "stylers": [{ "visibility": "off" }] },
    { "featureType": "transit.station.bus", "elementType": "labels.icon", "stylers": [{ "visibility": "on" }, { "weight": 2 }] }
  ]
  ''';

  // --- ROUTE START & END ---
  static const LatLng _origin = LatLng(6.91125032, 79.88253926);
  static const LatLng _destination = LatLng(6.92233663, 79.89160939);

  bool _isLoadingRoute = true;

  // --- PRESENTATION SIMULATION STATE ---
  List<LatLng> _masterRoute = [];
  List<LatLng> _currentPolyline = [];
  bool _isDemoRunning = false;
  Timer? _demoTimer;
  int _demoIndex = 0;

  Marker? _busMarker;
  Set<Marker> _passengerMarkers = {};
  Set<int> _activePassengerIndices = {};

  // --- BACKEND STATE ---
  bool _isOnline = true;
  StompClient? _stompClient;
  Timer? _connectionCheckTimer;
  DateTime _lastSuccessfulUpdate = DateTime.now();
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  bool _hasNotifiedOffline = false;

  @override
  void initState() {
    super.initState();
    _initNotifications();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchRealRoute();
    });

    _goOnline();
  }

  @override
  void dispose() {
    _stompClient?.deactivate();
    _connectionCheckTimer?.cancel();
    _demoTimer?.cancel();
    super.dispose();
  }

  // ==========================================
  // 1. FETCH REAL ROAD ROUTE VIA STATIC COORDINATES
  // ==========================================
  Future<void> _fetchRealRoute() async {
    setState(() => _isLoadingRoute = true);

    // Using the explicitly provided coordinates from route_data.dart
    // This perfectly snaps to the road as requested.
    _masterRoute = List.from(staticRouteCoordinates);

    if (!mounted) return;

    setState(() {
      _currentPolyline = List.from(_masterRoute);
      _updatePolyline();
      _isLoadingRoute = false;

      _busMarker = Marker(
        markerId: const MarkerId('bus_marker'),
        position: _masterRoute.first,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      );
    });
  }

  void _updatePolyline() {
    _polylines.clear();
    _polylines.add(
      Polyline(
        polylineId: const PolylineId('route_line'),
        color: const Color(0xFF1D5A94), // BusKo Blue
        width: 6,
        points: _currentPolyline,
        geodesic: true,
      ),
    );
  }

  // ==========================================
  // 2. CUSTOM PASSENGER MARKER GENERATOR
  // ==========================================
  Future<BitmapDescriptor> _createCustomMarkerIcon(String text) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    final Paint paint = Paint()..color = Colors.red;
    const double size = 100.0; // Size of the red circle

    // Draw the red circle
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2, paint);

    // Draw the number text in the center
    TextPainter painter = TextPainter(textDirection: TextDirection.ltr);
    painter.text = TextSpan(
      text: text,
      style: const TextStyle(
        fontSize: 60.0,
        color: Colors.white,
        fontWeight: FontWeight.bold,
      ),
    );
    painter.layout();
    painter.paint(
      canvas,
      Offset((size - painter.width) / 2, (size - painter.height) / 2),
    );

    final ui.Image image = await pictureRecorder.endRecording().toImage(size.toInt(), size.toInt());
    final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    final Uint8List uint8List = byteData!.buffer.asUint8List();

    return BitmapDescriptor.fromBytes(uint8List);
  }

  // ==========================================
  // 3. THE GHOST BUS DEMO LOGIC
  // ==========================================
  void _toggleDemoMode() async {
    if (_isDemoRunning) {
      _demoTimer?.cancel();
      setState(() {
        _isDemoRunning = false;
        _passengerMarkers.clear();
      });
      return;
    }

    // Safety guard: don't start if route is empty
    if (_masterRoute.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Route not loaded yet. Please wait or check your internet connection.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    _demoIndex = 0;

    // Reset polyline to full route before starting
    setState(() {
      _currentPolyline = List.from(_masterRoute);
      _updatePolyline();
      _busMarker = Marker(
        markerId: const MarkerId('bus_marker'),
        position: _masterRoute.first,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      );
    });

    // Wait for the custom red icons to be painted
    await _spawnMockPassengers();

    setState(() {
      _isDemoRunning = true;
    });

    _startDemoTimer();
  }

  void _startDemoTimer() {
    // Ticks every 300ms. Moving down the array makes the bus drive.
    _demoTimer = Timer.periodic(const Duration(milliseconds: 300), (timer) {
      if (_demoIndex >= _masterRoute.length) {
        timer.cancel();
        _showRouteCompleteDialog();
        setState(() => _isDemoRunning = false);
        return;
      }

      LatLng fakeLocation = _masterRoute[_demoIndex];

      setState(() {
        // 1. Move the bus icon
        _busMarker = Marker(
          markerId: const MarkerId('bus_marker'),
          position: fakeLocation,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        );

        // 2. Erase the blue line behind the bus (Pac-Man effect)
        _currentPolyline = _masterRoute.sublist(_demoIndex);
        _updatePolyline();
      });

      // 3. Pan the camera
      _mapController?.animateCamera(CameraUpdate.newLatLng(fakeLocation));

      // 4. Send fake location to Backend
      if (_isOnline && _stompClient != null && _stompClient!.connected) {
        final payload = jsonEncode({
          'lat': fakeLocation.latitude,
          'lng': fakeLocation.longitude,
          'busId': widget.busId,
          'routeId': widget.routeId
        });
        _stompClient!.send(destination: '/app/driver/update', body: payload);
        _lastSuccessfulUpdate = DateTime.now();
      }

      // 5. Check if we hit a passenger!
      if (_activePassengerIndices.contains(_demoIndex)) {
        timer.cancel(); // Pause the drive loop
        _handlePassengerPickup(_demoIndex);
      } else {
        _demoIndex++;
      }
    });
  }

  void _handlePassengerPickup(int index) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("🚌 Stopping to pick up passengers..."),
        duration: Duration(seconds: 2),
        backgroundColor: Colors.green,
      ),
    );

    // Pause for 2 seconds to simulate loading
    await Future.delayed(const Duration(seconds: 2));

    if (!mounted) return;

    setState(() {
      // Make the red dot disappear
      _passengerMarkers.removeWhere((m) => m.markerId.value == 'passenger_$index');
      _activePassengerIndices.remove(index);
    });

    // Resume the drive
    _demoIndex++;
    if (_isDemoRunning) {
      _startDemoTimer();
    }
  }

  Future<void> _spawnMockPassengers() async {
    _passengerMarkers.clear();
    _activePassengerIndices.clear();
    Random rand = Random();

    // Spawn 3 groups of passengers along the route
    List<double> milestones = [0.30, 0.60, 0.85];

    for (int i = 0; i < milestones.length; i++) {
      int pIndex = (_masterRoute.length * milestones[i]).toInt();
      _activePassengerIndices.add(pIndex);

      LatLng pLoc = _masterRoute[pIndex];
      int groupSize = rand.nextInt(4) + 1; // 1 to 4 passengers

      // Generate the red circle with the number painted inside
      BitmapDescriptor customIcon = await _createCustomMarkerIcon(groupSize.toString());

      setState(() {
        _passengerMarkers.add(
            Marker(
              markerId: MarkerId('passenger_$pIndex'),
              position: pLoc,
              icon: customIcon,
            )
        );
      });
    }
  }

  void _showRouteCompleteDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Route Complete!'),
        content: const Text('You have reached the end of the route. Start return journey?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  // ==========================================
  // STOMP / OFFLINE LOGIC
  // ==========================================
  Future<void> _initNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
    await _notificationsPlugin.initialize(settings: initializationSettings);
  }

  void _goOnline() {
    _stompClient = StompClient(
      config: StompConfig(
        url: dotenv.env['WS_SERVER_URL'] ?? '',
        onConnect: (frame) => debugPrint('STOMP Connected on Map'),
      ),
    );
    _stompClient!.activate();
    setState(() {
      _isOnline = true;
      _lastSuccessfulUpdate = DateTime.now();
    });
    _startWatchdogTimer();
  }

  void _startWatchdogTimer() {
    _connectionCheckTimer?.cancel();
    _connectionCheckTimer = Timer.periodic(const Duration(seconds: 15), (timer) async {
      if (!_isOnline) return;
      if (DateTime.now().difference(_lastSuccessfulUpdate).inSeconds > 20 && !_hasNotifiedOffline) {
        var connectivityResult = await (Connectivity().checkConnectivity());
        if (connectivityResult.contains(ConnectivityResult.none)) {
          _hasNotifiedOffline = true;
          await _notificationsPlugin.show(
            id: 0,
            title: '⚠️ Connection Lost',
            body: 'Live broadcast paused. Please check internet.',
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails('busko_offline', 'Alerts', importance: Importance.max),
            ),
          );
        }
      }
    });
  }

  // ==========================================
  // UI BUILD
  // ==========================================
  @override
  Widget build(BuildContext context) {
    Set<Marker> allMarkers = {};

    // Always show start & end markers
    allMarkers.add(
      Marker(
        markerId: const MarkerId('start_marker'),
        position: _origin,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: const InfoWindow(title: 'Start', snippet: 'Keells Angoda'),
      ),
    );
    allMarkers.add(
      Marker(
        markerId: const MarkerId('end_marker'),
        position: _destination,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: const InfoWindow(title: 'End', snippet: 'Buddhist Ladies College'),
      ),
    );

    allMarkers.addAll(_passengerMarkers);
    if (_busMarker != null) {
      allMarkers.add(_busMarker!);
    }

    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            mapType: MapType.normal,
            initialCameraPosition: _initialPosition,
            trafficEnabled: true,
            myLocationEnabled: false, // Prevents fake emulator location from showing
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            polylines: _polylines,
            markers: allMarkers,
            onMapCreated: (GoogleMapController controller) {
              _mapController = controller;
              controller.setMapStyle(_mapStyle);

              if (_masterRoute.isNotEmpty) {
                controller.animateCamera(CameraUpdate.newLatLngZoom(_masterRoute.first, 15.0));
              }
            },
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Align(
                alignment: Alignment.topLeft,
                child: FloatingActionButton.small(
                  heroTag: "btn_back",
                  backgroundColor: Colors.white,
                  child: const Icon(Icons.arrow_back, color: Colors.black87),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(top: 16.0),
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
                  ),
                  child: Text(
                    widget.directionTitle,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          ),

          // Loading indicator while route is being fetched
          if (_isLoadingRoute)
            const Center(
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(20.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Loading route...', style: TextStyle(fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ),
            ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: FloatingActionButton.extended(
                  heroTag: "btn_demo",
                  backgroundColor: _isLoadingRoute
                      ? Colors.grey
                      : (_isDemoRunning ? Colors.red : Colors.green[600]),
                  onPressed: _isLoadingRoute ? null : _toggleDemoMode,
                  icon: Icon(
                    _isLoadingRoute
                        ? Icons.hourglass_empty
                        : (_isDemoRunning ? Icons.stop : Icons.play_arrow),
                    color: Colors.white,
                  ),
                  label: Text(
                    _isLoadingRoute
                        ? 'Loading...'
                        : (_isDemoRunning ? 'Stop Demo' : 'Run Demo'),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}