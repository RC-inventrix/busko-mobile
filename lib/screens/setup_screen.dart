import 'package:flutter/material.dart';
import 'broadcast_screen.dart'; // Import the screen we navigate to

class DriverSetupScreen extends StatefulWidget {
  const DriverSetupScreen({super.key});

  @override
  State<DriverSetupScreen> createState() => _DriverSetupScreenState();
}

class _DriverSetupScreenState extends State<DriverSetupScreen> {
  final TextEditingController _routeNumberController = TextEditingController();
  String? _selectedDirection;
  bool _isLoading = false;

  final List<String> _directions = [
    'Start to End (Forward)',
    'End to Start (Return)',
  ];

  Future<void> _startShift() async {
    if (_routeNumberController.text.isEmpty || _selectedDirection == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all fields')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    // Simulating backend API call for /api/driver/startShift
    await Future.delayed(const Duration(seconds: 1));
    int generatedBusId = DateTime.now().millisecondsSinceEpoch % 1000;
    int selectedRouteId = int.tryParse(_routeNumberController.text) ?? 1;

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => DriverScreen(
            busId: generatedBusId,
            routeId: selectedRouteId,
            routeDisplay: _routeNumberController.text,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
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
              const SizedBox(height: 8),
              Text(
                'Enter your route details to begin broadcasting.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              TextField(
                controller: _routeNumberController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Route Number',
                  prefixIcon: Icon(Icons.directions_bus),
                  hintText: 'e.g. 138',
                ),
              ),
              const SizedBox(height: 24),
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Direction',
                  prefixIcon: Icon(Icons.swap_calls),
                ),
                value: _selectedDirection,
                items: _directions.map((String direction) {
                  return DropdownMenuItem(
                    value: direction,
                    child: Text(direction),
                  );
                }).toList(),
                onChanged: (String? newValue) {
                  setState(() {
                    _selectedDirection = newValue;
                  });
                },
              ),
              const SizedBox(height: 48),
              SizedBox(
                height: 56,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _startShift,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.secondary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  child: _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('Start Shift'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}