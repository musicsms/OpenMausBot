import 'package:flutter/material.dart';

void main() {
  runApp(const MausBotApp());
}

class MausBotApp extends StatelessWidget {
  const MausBotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenMausBot',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          surface: Colors.black,
          primary: Colors.white,
        ),
      ),
      home: const Scaffold(
        body: Center(
          child: Text('OpenMausBot', style: TextStyle(color: Colors.white, fontSize: 24)),
        ),
      ),
    );
  }
}
