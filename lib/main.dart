import 'package:client/desktop_screen.dart';
import 'package:client/mobile_screen.dart';
import 'package:flutter/material.dart';
import 'dart:io';

void main() {
  runApp(const ShadowSyncP2PApp());
}

class ShadowSyncP2PApp extends StatelessWidget {
  const ShadowSyncP2PApp({super.key});

  @override
  Widget build(BuildContext context) {
    bool isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

    return MaterialApp(
      title: 'ShadowSync Premium',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00CEC9),
          brightness: Brightness.dark,
          surface: const Color(0xFF111217),
          // background: const Color(0xFF090A0F),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF171923),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          elevation: 6,
        ),
      ),
      home: isDesktop ? const DesktopP2PHostView() : const MobileP2PClientView(),
    );
  }
}
