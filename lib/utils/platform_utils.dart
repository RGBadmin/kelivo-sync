import 'dart:io' show Platform, exit;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart' show SystemNavigator;

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
      // The restart plugin only recreates the activity on some devices,
      // which brings the user back to a half-initialized UI instead of a
      // clean relaunch. A plain exit is predictable: the user relaunches
      // from the launcher and everything loads fresh.
      await SystemNavigator.pop();
      exit(0);
    } else {
      exit(0);
    }
  }
}
