import 'dart:io' show Platform, exit;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:restart_app/restart_app.dart';

abstract final class PlatformUtils {
  PlatformUtils._();

  static bool get isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  static bool get isDesktopTarget =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  static bool get isMobileTarget =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static bool get isMacOS => Platform.isMacOS;

  static bool get isWindows => Platform.isWindows;

  static bool get isLinux => Platform.isLinux;

  static bool get isAndroid => Platform.isAndroid;

  static bool get isIOS => Platform.isIOS;

  static Future<void> restartApp() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      // The restart plugin fails silently on some Android versions; falling
      // back to a plain exit still fulfils "restart to load the new data" —
      // the user relaunches from the launcher.
      try {
        final result = await Restart.restartApp(mode: RestartMode.process);
        if (result.success) return;
      } catch (_) {}
      await SystemNavigator.pop();
      exit(0);
    } else {
      exit(0);
    }
  }
}
