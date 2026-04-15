// import 'package:flutter/material.dart';
// import 'upload_screen.dart';

// void main() {
//   runApp(const MyApp());
// }

// class MyApp extends StatelessWidget {
//   const MyApp({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return const MaterialApp(
//       debugShowCheckedModeBanner: false,
//       home: UploadScreen(), // 🔥 THIS LINE FIXES EVERYTHING
//     );
//   }
// }

import 'package:flutter/material.dart';
import 'screens/dashboard_screen.dart';

void main() => runApp(const SmartSupplyApp());

class SmartSupplyChainApp extends StatelessWidget {
  const SmartSupplyChainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Supply Chain',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1D9E75)),
        useMaterial3: true,
        fontFamily: 'Arial',
      ),
      home: const DashboardScreen(),
    );
  }
}