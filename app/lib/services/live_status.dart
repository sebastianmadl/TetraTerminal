import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Hands the radio status to iOS: the Live Activity (Lock Screen and Dynamic
/// Island) and the home screen widget. Native side: ios_widgets/Runner/TetraLivePlugin.swift.
/// Other platforms: no-op.
class LiveStatus {
  static const _channel = MethodChannel('tetra/live');
  Map<String, Object?>? _last;
  bool _unavailable = !kIsWeb && !Platform.isIOS;

  /// Sends [status] when it changed since the last call.
  Future<void> update(Map<String, Object?> status) async {
    if (_unavailable || mapEquals(status, _last)) return;
    _last = status;
    await _call('update', status);
  }

  /// Ends the Live Activity (the widget keeps the last status).
  Future<void> end() async {
    if (_unavailable) return;
    _last = null;
    await _call('end', null);
  }

  Future<void> _call(String method, Object? args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      _unavailable = true; // built without the widget extension
    } catch (e) {
      debugPrint('live status: $e');
    }
  }
}
