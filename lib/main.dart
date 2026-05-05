import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/setup_screen.dart';
import 'screens/broadcast_screen.dart'; // Ensure this path matches your folder structure

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint("Warning: .env file is empty or missing.");
  }

  runApp(const DriverApp());
}

class DriverApp extends StatelessWidget {
  const DriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BusKo Driver',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1D5A94),
          primary: const Color(0xFF1D5A94),
          secondary: const Color(0xFFF28F20),
        ),
        useMaterial3: true,
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF1D5A94), width: 2),
          ),
        ),
      ),
      // App now starts on the loading screen to check registration
      home: const InitialLoadingScreen(),
    );
  }
}

// --- NEW COMPONENT: The Loading & Routing Screen ---
class InitialLoadingScreen extends StatefulWidget {
  const InitialLoadingScreen({super.key});

  @override
  State<InitialLoadingScreen> createState() => _InitialLoadingScreenState();
}

class _InitialLoadingScreenState extends State<InitialLoadingScreen> {
  @override
  void initState() {
    super.initState();
    _checkRegistration();
  }

  Future<void> _checkRegistration() async {
    final prefs = await SharedPreferences.getInstance();

    // Check if the phone remembers being registered
    final savedBusId = prefs.getInt('busId');
    final savedRouteId = prefs.getInt('routeId');
    final savedRouteDisplay = prefs.getString('routeDisplay');

    // Add a tiny artificial delay so the splash screen doesn't flash violently
    await Future.delayed(const Duration(milliseconds: 500));

    if (mounted) {
      if (savedBusId != null && savedRouteId != null && savedRouteDisplay != null) {
        // Device is registered! Skip setup and go to Broadcast Screen
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => DriverScreen(
              busId: savedBusId,
              routeId: savedRouteId,
              routeDisplay: savedRouteDisplay,
            ),
          ),
        );
      } else {
        // Device is clean. Go to Setup Screen
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const DriverSetupScreen()),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/logo.png',
              height: 100,
              errorBuilder: (context, error, stackTrace) =>
              const Icon(Icons.directions_bus, size: 100, color: Color(0xFF1D5A94)),
            ),
            const SizedBox(height: 32),
            const CircularProgressIndicator(color: Color(0xFF1D5A94)),
          ],
        ),
      ),
    );
  }
}