import 'package:flutter/material.dart';

void main() => runApp(const ClubinsApp());

/// Placeholder app shell — real OIDC sign-in and the venues UI land later.
class ClubinsApp extends StatelessWidget {
  const ClubinsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Clubins',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Clubins auth reference')),
    );
  }
}
