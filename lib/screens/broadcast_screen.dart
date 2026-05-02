import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:stomp_dart_client/stomp_dart_client.dart';

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
  String _statusMessage = 'Press Go Online to start';
  StompClient? _stompClient;
  StreamSubscription<Position>? _positionSubscription;

  @override
  void dispose() {
    _goOffline();
    super.dispose();
  }

  Future<void> _goOnline() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() => _statusMessage = 'Location permission denied');
        return;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      setState(() => _statusMessage = 'Location permission permanently denied');
      return;
    }

    setState(() {
      _isOnline = true;
      _statusMessage = 'Connecting to server...';
    });

    _stompClient = StompClient(
      config: StompConfig(
        url: dotenv.env['WS_SERVER_URL'] ?? '',
        onConnect: _onStompConnect,
        onWebSocketError: (dynamic error) {
          if (mounted) setState(() => _statusMessage = 'WebSocket error: $error');
        },
        onDisconnect: (frame) {
          if (mounted) setState(() => _statusMessage = 'Disconnected from server');
        },
        onStompError: (frame) {
          if (mounted) setState(() => _statusMessage = 'STOMP error: ${frame.body}');
        },
      ),
    );
    _stompClient!.activate();
  }

  void _onStompConnect(StompFrame frame) {
    if (!mounted) return;
    setState(() => _statusMessage = 'Connected. Waiting for GPS...');

    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
    );

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

        if (mounted) {
          setState(() {
            _statusMessage =
            'lat=${position.latitude.toStringAsFixed(5)}, '
                'lng=${position.longitude.toStringAsFixed(5)}';
          });
        }
      },
      onError: (dynamic error) {
        if (mounted) setState(() => _statusMessage = 'GPS error: $error');
      },
    );
  }

  void _goOffline() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _stompClient?.deactivate();
    _stompClient = null;
    if (mounted) {
      setState(() {
        _isOnline = false;
        _statusMessage = 'Press Go Online to start';
      });
    }
  }

  void _toggleOnlineStatus() {
    if (_isOnline) {
      _goOffline();
    } else {
      _goOnline();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        title: Text('Route ${widget.routeDisplay}'),
        centerTitle: true,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _isOnline ? Icons.sensors : Icons.sensors_off,
              size: 100,
              color: _isOnline ? Theme.of(context).colorScheme.secondary : Colors.grey,
            ),
            const SizedBox(height: 24),
            Text(
              _isOnline ? 'Broadcasting Live' : 'Offline',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: _isOnline ? Theme.of(context).colorScheme.secondary : Colors.grey,
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
                    color: Colors.grey[700]
                ),
              ),
            ),
            const SizedBox(height: 56),
            ElevatedButton(
              onPressed: _toggleOnlineStatus,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isOnline ? Colors.red[600] : Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 48,
                  vertical: 16,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                elevation: 4,
                textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              child: Text(_isOnline ? 'End Broadcasting' : 'Go Online'),
            ),
          ],
        ),
      ),
    );
  }
}