import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/controllers/auth_controller.dart';
import 'src/controllers/tracking_controller.dart';
import 'src/services/backend_api.dart';
import 'src/services/local_store.dart';
import 'src/ui/auth_screen.dart';
import 'src/ui/map_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final localStore = LocalStore(preferences);
  final api = BackendApi();
  final authController = AuthController(api: api, localStore: localStore);
  await authController.initialize();
  final trackingController = TrackingController(
    api: api,
    authController: authController,
    localStore: localStore,
  );
  await trackingController.initialize();

  runApp(
    YurumeApp(
      authController: authController,
      trackingController: trackingController,
    ),
  );
}

class YurumeApp extends StatelessWidget {
  const YurumeApp({
    super.key,
    required this.authController,
    required this.trackingController,
  });

  final AuthController authController;
  final TrackingController trackingController;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthController>.value(value: authController),
        ChangeNotifierProvider<TrackingController>.value(
          value: trackingController,
        ),
      ],
      child: MaterialApp(
        title: 'Yurume',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1A9A5F)),
          scaffoldBackgroundColor: const Color(0xFFF6F8F6),
          useMaterial3: true,
        ),
        home: const _RootScreen(),
      ),
    );
  }
}

class _RootScreen extends StatelessWidget {
  const _RootScreen();

  @override
  Widget build(BuildContext context) {
    final authController = context.watch<AuthController>();
    if (!authController.initialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!authController.isAuthenticated) {
      return const AuthScreen();
    }

    return const MapScreen();
  }
}
