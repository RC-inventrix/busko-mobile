import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:stomp_dart_client/stomp_dart_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'setup_screen.dart';
import 'map_screen.dart'; // NEW IMPORT FOR THE MAP SCREEN

class DriverScreen extends StatefulWidget {
  final int busId;
  final int routeId;
  final String routeDisplay;

  const DriverScreen({
    super.key,
    required this.busId,
    required this.routeId,
    required this.routeDisplay,
  });

  @override
  State<DriverScreen> createState() => _DriverScreenState();
}

class _DriverScreenState extends State<DriverScreen> {
  bool _isOnline = false;
  bool _isProcessing = false;
  String _statusMessage = 'Press Go Online to start';

  StompClient? _stompClient;
  StreamSubscription<Position>? _positionSubscription;

  Timer? _connectionCheckTimer;
  DateTime _lastSuccessfulUpdate = DateTime.now();
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  bool _hasNotifiedOffline = false;

  @override
  void initState() {
    super.initState();
    _initNotifications();
  }

  Future<void> _initNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
    AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings =
    InitializationSettings(android: initializationSettingsAndroid);

    await _notificationsPlugin.initialize(
      settings: initializationSettings,
    );
  }

  @override
  void dispose() {
    _goOffline();
    super.dispose();
  }

  Future<void> _goOnline() async {
    await Permission.notification.request();

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() => _statusMessage = 'Location permission denied');
        return;
      }
    }

    if (permission == LocationPermission.whileInUse) {
      await Permission.locationAlways.request();
    }

    setState(() {
      _isOnline = true;
      _statusMessage = 'Connecting to server...';
      _hasNotifiedOffline = false;
      _lastSuccessfulUpdate = DateTime.now();
    });

    _stompClient = StompClient(
      config: StompConfig(
        url: dotenv.env['WS_SERVER_URL'] ?? '',
        onConnect: _onStompConnect,
        onWebSocketError: (dynamic error) {
          if (mounted) setState(() => _statusMessage = 'Connection lost. Retrying...');
        },
        onDisconnect: (frame) {
          if (mounted) setState(() => _statusMessage = 'Disconnected from server');
        },
      ),
    );
    _stompClient!.activate();

    _startWatchdogTimer();
  }

  void _onStompConnect(StompFrame frame) {
    if (!mounted) return;
    setState(() => _statusMessage = 'Connected. Waiting for GPS...');

    late LocationSettings locationSettings;

    if (defaultTargetPlatform == TargetPlatform.android) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        intervalDuration: const Duration(seconds: 10),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationText: "Broadcasting your live location to passengers",
          notificationTitle: "BusKo Driver Online",
          enableWakeLock: true,
        ),
      );
    } else {
      locationSettings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      );
    }

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
          (Position position) {
        final payload = jsonEncode({
          'lat': position.latitude,
          'lng': position.longitude,
          'busId': widget.busId,
          'routeId': widget.routeId
        });

        _stompClient?.send(
          destination: '/app/driver/update',
          body: payload,
        );

        _lastSuccessfulUpdate = DateTime.now();
        _hasNotifiedOffline = false;

        if (mounted) {
          setState(() {
            _statusMessage =
            'Live: Lat ${position.latitude.toStringAsFixed(4)}, Lng ${position.longitude.toStringAsFixed(4)}\nUpdating every 10s';
          });
        }
      },
      onError: (dynamic error) {
        if (mounted) setState(() => _statusMessage = 'GPS error: Check device location settings');
      },
    );
  }

  void _startWatchdogTimer() {
    _connectionCheckTimer?.cancel();
    _connectionCheckTimer = Timer.periodic(const Duration(seconds: 15), (timer) async {
      if (!_isOnline) return;

      final secondsSinceLastUpdate = DateTime.now().difference(_lastSuccessfulUpdate).inSeconds;

      if (secondsSinceLastUpdate > 20 && !_hasNotifiedOffline) {
        var connectivityResult = await (Connectivity().checkConnectivity());

        if (connectivityResult.contains(ConnectivityResult.none)) {
          _hasNotifiedOffline = true;
          _showOfflineNotification();
          if (mounted) {
            setState(() => _statusMessage = 'OFFLINE: No Internet Connection. Passengers are seeing your last known location.');
          }
        }
      }
    });
  }

  Future<void> _showOfflineNotification() async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'busko_offline_channel',
      'Connection Alerts',
      channelDescription: 'Alerts when the driver loses internet connection',
      importance: Importance.max,
      priority: Priority.high,
      color: Color(0xFF1D5A94),
      playSound: true,
      enableVibration: true,
    );
    const NotificationDetails platformDetails = NotificationDetails(android: androidDetails);

    await _notificationsPlugin.show(
      id: 0,
      title: '⚠️ Connection Lost',
      body: 'Your live location is paused. Please check your internet connection.',
      notificationDetails: platformDetails,
    );
  }

  Future<void> _goOffline() async {
    if (_positionSubscription != null) {
      await _positionSubscription!.cancel();
      _positionSubscription = null;
    }

    _stompClient?.deactivate();
    _stompClient = null;
    _connectionCheckTimer?.cancel();
    _connectionCheckTimer = null;
    _hasNotifiedOffline = false;

    if (mounted) {
      setState(() {
        _isOnline = false;
        _statusMessage = 'Press Go Online to start';
      });
    }
  }

  Future<void> _toggleOnlineStatus() async {
    if (_isProcessing) return;

    setState(() => _isProcessing = true);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const CircularProgressIndicator(color: Color(0xFF1D5A94)),
          ),
        ),
      ),
    );

    await Future.delayed(const Duration(milliseconds: 150));

    try {
      if (_isOnline) {
        await _goOffline();
      } else {
        await _goOnline();
      }
    } finally {
      if (mounted) {
        Navigator.pop(context);
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _endShift() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const CircularProgressIndicator(color: Color(0xFF1D5A94)),
          ),
        ),
      ),
    );
    await Future.delayed(const Duration(milliseconds: 150));

    await _goOffline();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    if (mounted) {
      Navigator.pop(context);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const DriverSetupScreen()),
      );
    }
  }

  void _showDirectionCheck() {
    List<String> parts = widget.routeDisplay.split(': ');
    String routeLocations = parts.length > 1 ? parts[1] : widget.routeDisplay;
    List<String> locations = routeLocations.split(' to ');

    String startCity = locations.isNotEmpty ? locations[0].trim() : 'Start Point';
    String endCity = locations.length > 1 ? locations[1].trim() : 'End Point';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Direction'),
        content: const Text('Which way are you driving for this trip?'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => MapScreen(
                  busId: widget.busId,
                  routeId: widget.routeId,
                  directionTitle: '$startCity to $endCity',
                  startLocationName: startCity,
                  endLocationName: endCity,
                )),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Colors.white),
            child: Text('$startCity ➔ $endCity'),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => MapScreen(
                  busId: widget.busId,
                  routeId: widget.routeId,
                  directionTitle: '$endCity to $startCity',
                  startLocationName: endCity,
                  endLocationName: startCity,
                )),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.secondary, foregroundColor: Colors.white),
            child: Text('$endCity ➔ $startCity'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text('Route ${widget.routeDisplay}', style: const TextStyle(fontSize: 16)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Image.asset(
                  'assets/logo.png',
                  height: 80,
                  errorBuilder: (context, error, stackTrace) =>
                      Icon(Icons.directions_bus, size: 80, color: Theme.of(context).colorScheme.primary),
                ),
              ),
              const SizedBox(height: 32),

              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _isOnline ? Icons.sensors : Icons.sensors_off,
                        size: 90,
                        color: _isOnline ? Colors.green : Colors.grey[400],
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _isOnline ? 'Broadcasting Live' : 'Offline',
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          color: _isOnline ? Colors.green : Colors.grey[600],
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          _statusMessage,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: _statusMessage.contains('OFFLINE') ? Colors.red : Colors.grey[700],
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),

              ElevatedButton.icon(
                onPressed: _isProcessing ? null : _toggleOnlineStatus,
                icon: _isProcessing
                    ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
                )
                    : Icon(_isOnline ? Icons.stop_circle : Icons.play_circle),
                label: Text(_isProcessing
                    ? 'Processing...'
                    : (_isOnline ? 'Stop Broadcasting' : 'Go Online')),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isOnline ? Colors.red[600] : Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 2,
                  textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 16),

              // --- BUTTON ONLY VISIBLE WHEN BROADCASTING ---
              if (_isOnline) ...[
                OutlinedButton.icon(
                  onPressed: _isProcessing ? null : _showDirectionCheck,
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('Open Live Navigation'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.primary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    side: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              TextButton.icon(
                onPressed: _isProcessing ? null : () {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Register New Route?'),
                      content: const Text('This will end your current shift and allow you to select a new route.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(context);
                            _endShift();
                          },
                          child: const Text('Confirm', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  );
                },
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Register New Route'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.grey[700],
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}