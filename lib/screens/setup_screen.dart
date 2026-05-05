import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart'; // Local storage for registration
import 'broadcast_screen.dart'; // Import the screen we navigate to

// --- Simple Model for the Route Data ---
class RouteModel {
  final int id;
  final String routeNumber;
  final String startLocation;
  final String endLocation;

  RouteModel({
    required this.id,
    required this.routeNumber,
    required this.startLocation,
    required this.endLocation,
  });

  factory RouteModel.fromJson(Map<String, dynamic> json) {
    return RouteModel(
      id: json['id'],
      routeNumber: json['routeNumber'],
      startLocation: json['startLocation'],
      endLocation: json['endLocation'],
    );
  }
}

class DriverSetupScreen extends StatefulWidget {
  const DriverSetupScreen({super.key});

  @override
  State<DriverSetupScreen> createState() => _DriverSetupScreenState();
}

class _DriverSetupScreenState extends State<DriverSetupScreen> {
  final String backendUrl = 'http://10.0.2.2:8080'; // Localhost for Android Emulator

  bool _isLoading = false;
  bool _isSearching = false; // Tracks API loading state
  String? _routeSearchError; // Shows validation errors in the UI

  // State variables for the cascading selection
  List<RouteModel> _fetchedRoutes = [];
  String? _selectedRouteNumber;
  String? _selectedStartLocation;
  String? _selectedEndLocation;
  RouteModel? _finalSelectedRoute;

  // 1. Fetch autocomplete suggestions from Spring Boot
  Future<List<String>> _searchRouteNumbers(String query) async {
    if (query.isEmpty) {
      setState(() => _routeSearchError = null);
      return [];
    }

    setState(() {
      _isSearching = true;
      _routeSearchError = null;
    });

    try {
      final response = await http.get(Uri.parse('$backendUrl/api/routes/search?query=$query'));

      if (response.statusCode == 200) {
        List<dynamic> data = json.decode(response.body);
        _fetchedRoutes = data.map((json) => RouteModel.fromJson(json)).toList();

        // Return only unique route numbers for the first dropdown
        final uniqueRoutes = _fetchedRoutes.map((r) => r.routeNumber).toSet().toList();

        setState(() {
          if (uniqueRoutes.isEmpty) {
            _routeSearchError = 'Route not found';
          } else {
            _routeSearchError = null;
          }
        });

        return uniqueRoutes;
      } else {
        setState(() => _routeSearchError = 'Server error (${response.statusCode})');
        debugPrint('Backend rejected request. Status: ${response.statusCode}, Body: ${response.body}');
      }
    } catch (e) {
      debugPrint('Error fetching routes: $e');
      setState(() => _routeSearchError = 'Network error. Backend unreachable.');
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
    return [];
  }

  // 2. Start the shift and create the Bus record
  Future<void> _startShift() async {
    if (_finalSelectedRoute == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please complete route selection')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Create the Bus record in the backend
      final response = await http.post(
        Uri.parse('$backendUrl/api/buses/start?routeId=${_finalSelectedRoute!.id}'),
      );

      if (response.statusCode == 200) {
        final busData = json.decode(response.body);
        final generatedBusId = busData['id'];
        final displayString = '${_finalSelectedRoute!.routeNumber}: ${_finalSelectedRoute!.startLocation} to ${_finalSelectedRoute!.endLocation}';

        // --- NEW LOGIC: Save the identifiers to the phone's hard drive ---
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('busId', generatedBusId);
        await prefs.setInt('routeId', _finalSelectedRoute!.id);
        await prefs.setString('routeDisplay', displayString);

        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => DriverScreen(
                busId: generatedBusId,
                routeId: _finalSelectedRoute!.id,
                routeDisplay: displayString,
              ),
            ),
          );
        }
      } else {
        throw Exception('Failed to create bus. Status: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error starting shift: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Filter available start locations based on selected route number
    List<String> availableStartLocations = _selectedRouteNumber == null
        ? []
        : _fetchedRoutes
        .where((r) => r.routeNumber == _selectedRouteNumber)
        .map((r) => r.startLocation)
        .toSet()
        .toList();

    // Filter available end locations based on selected route number AND start location
    List<String> availableEndLocations = _selectedStartLocation == null
        ? []
        : _fetchedRoutes
        .where((r) => r.routeNumber == _selectedRouteNumber && r.startLocation == _selectedStartLocation)
        .map((r) => r.endLocation)
        .toSet()
        .toList();

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              Image.asset(
                'assets/logo.png',
                height: 120,
                errorBuilder: (context, error, stackTrace) =>
                const Icon(Icons.directions_bus, size: 120, color: Color(0xFF1D5A94)),
              ),
              const SizedBox(height: 40),
              Text(
                'Driver Setup',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),

              // 1. Route Number Autocomplete
              Autocomplete<String>(
                optionsBuilder: (TextEditingValue textEditingValue) {
                  return _searchRouteNumbers(textEditingValue.text);
                },
                onSelected: (String selection) {
                  setState(() {
                    _selectedRouteNumber = selection;
                    _selectedStartLocation = null; // Reset children
                    _selectedEndLocation = null;
                    _finalSelectedRoute = null;
                    _routeSearchError = null; // Clear error upon valid selection
                  });
                },
                fieldViewBuilder: (context, controller, focusNode, onEditingComplete) {
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: (value) {
                      // IF the user modifies the text after selecting, completely reset the cascade
                      if (_selectedRouteNumber != null) {
                        setState(() {
                          _selectedRouteNumber = null;
                          _selectedStartLocation = null;
                          _selectedEndLocation = null;
                          _finalSelectedRoute = null;
                        });
                      }
                    },
                    decoration: InputDecoration(
                      labelText: 'Search Route Number',
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'e.g. 138',
                      errorText: _routeSearchError, // Will turn red if route is invalid
                      suffixIcon: _isSearching
                          ? const Padding(
                        padding: EdgeInsets.all(12.0),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                          : null,
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),

              // 2. Start Location Dropdown
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Start Location',
                  prefixIcon: Icon(Icons.location_on),
                ),
                value: _selectedStartLocation,
                items: availableStartLocations.map((String location) {
                  return DropdownMenuItem(value: location, child: Text(location));
                }).toList(),
                onChanged: _selectedRouteNumber == null ? null : (String? newValue) {
                  setState(() {
                    _selectedStartLocation = newValue;
                    _selectedEndLocation = null; // Reset child
                    _finalSelectedRoute = null;
                  });
                },
              ),
              const SizedBox(height: 24),

              // 3. End Location Dropdown
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'End Location',
                  prefixIcon: Icon(Icons.flag),
                ),
                value: _selectedEndLocation,
                items: availableEndLocations.map((String location) {
                  return DropdownMenuItem(value: location, child: Text(location));
                }).toList(),
                onChanged: _selectedStartLocation == null ? null : (String? newValue) {
                  setState(() {
                    _selectedEndLocation = newValue;
                    // Find the exact route object now that we have all three pieces of info
                    _finalSelectedRoute = _fetchedRoutes.firstWhere(
                            (r) => r.routeNumber == _selectedRouteNumber &&
                            r.startLocation == _selectedStartLocation &&
                            r.endLocation == _selectedEndLocation
                    );
                  });
                },
              ),
              const SizedBox(height: 48),

              // 4. Save & Start Button
              SizedBox(
                height: 56,
                child: ElevatedButton(
                  onPressed: (_isLoading || _finalSelectedRoute == null) ? null : _startShift,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.secondary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('Start Shift', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}