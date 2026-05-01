import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:stomp_dart_client/stomp_dart_client.dart';

void main() {
  runApp(const DriverApp());
}

class DriverApp extends StatelessWidget {
  const DriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Busko Driver',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const DriverScreen(),
    );
  }
}

class DriverScreen extends StatefulWidget {
  const DriverScreen({super.key});

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
        setState(() {
          _statusMessage = 'Location permission denied';
        });
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      setState(() {
        _statusMessage = 'Location permission permanently denied';
      });
      return;
    }

    setState(() {
      _isOnline = true;
      _statusMessage = 'Connecting to server...';
    });

    // --- UPDATED AWS SERVER URL BELOW ---
    _stompClient = StompClient(
      config: StompConfig(
        url: 'ws://192.168.8.157:8080/ws',
        onConnect: _onStompConnect,
        onWebSocketError: (dynamic error) {
          if (mounted) {
            setState(() {
              _statusMessage = 'WebSocket error: $error';
            });
          }
        },
        onDisconnect: (frame) {
          if (mounted) {
            setState(() {
              _statusMessage = 'Disconnected from server';
            });
          }
        },
        onStompError: (frame) {
          if (mounted) {
            setState(() {
              _statusMessage = 'STOMP error: ${frame.body}';
            });
          }
        },
      ),
    );
    _stompClient!.activate();
  }

  void _onStompConnect(StompFrame frame) {
    if (!mounted) return;
    setState(() {
      _statusMessage = 'Connected. Waiting for GPS...';
    });

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
          'busId': 1,      // Add this!
          'routeId': 1     // Add this!
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
        if (mounted) {
          setState(() {
            _statusMessage = 'GPS error: $error';
          });
        }
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
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Driver Interface'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _isOnline ? Icons.location_on : Icons.location_off,
              size: 80,
              color: _isOnline ? Colors.green : Colors.grey,
            ),
            const SizedBox(height: 24),
            Text(
              _isOnline ? 'Online' : 'Offline',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: _isOnline ? Colors.green : Colors.grey,
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: _toggleOnlineStatus,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isOnline ? Colors.red : Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 48,
                  vertical: 16,
                ),
                textStyle: const TextStyle(fontSize: 20),
              ),
              child: Text(_isOnline ? 'Go Offline' : 'Go Online'),
            ),
          ],
        ),
      ),
    );
  }
}