import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// What `show()` returns. Every failure is [noFill]; the plugin never throws into your app.
enum FountisResult { noFill, dismissed, completed }

/// Anonymous lifecycle event. Carries no survey titles, topics or answers.
class FountisEvent {
  const FountisEvent(this.type, [this.offerId]);

  /// `shown`, `dismissed`, `completed`, `noFill`, `notified` (and `started` on the web).
  final String type;
  final String? offerId;

  @override
  String toString() => 'FountisEvent($type, $offerId)';
}

/// Returns the signed user token from your server, or null when nobody is signed in.
/// Throw when you cannot get one (for example your token endpoint failed): nothing is shown, and the person is never
/// treated as a guest. No answer within 10 seconds also counts as a failure.
typedef FountisTokenProvider = Future<String?> Function();

FountisResult fountisResultFromName(Object? name) => switch (name) {
      'completed' => FountisResult.completed,
      'dismissed' => FountisResult.dismissed,
      _ => FountisResult.noFill,
    };

abstract class FountisConnectPlatform extends PlatformInterface {
  FountisConnectPlatform() : super(token: _token);

  static final Object _token = Object();
  static FountisConnectPlatform _instance = MethodChannelFountisConnect();

  static FountisConnectPlatform get instance => _instance;

  static set instance(FountisConnectPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<void> start({required String key, String? apiBase}) => throw UnimplementedError();
  void setUserToken(FountisTokenProvider? provider) => throw UnimplementedError();
  Future<void> enableNotifications() => throw UnimplementedError();
  Future<FountisResult> show() => throw UnimplementedError();
  Future<bool> handlePush(Map<String, dynamic> data) => throw UnimplementedError();
  Future<void> setUserConsent(bool granted) => throw UnimplementedError();
  Future<void> signOut() => throw UnimplementedError();
  Stream<FountisEvent> get onEvent => throw UnimplementedError();
}

/// iOS and Android: one MethodChannel to the native SDKs.
///
/// Dart -> native: start, setTokenProviderEnabled, resolveToken, rejectToken, enableNotifications, show, handlePush,
/// setUserConsent, signOut. Native -> Dart: `tokenRequest` (an id; Dart answers with resolveToken, or with rejectToken
/// when the provider throws) and `event`.
class MethodChannelFountisConnect extends FountisConnectPlatform {
  MethodChannelFountisConnect() {
    WidgetsFlutterBinding.ensureInitialized();
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const MethodChannel _channel = MethodChannel('org.fountis.connect/methods');

  FountisTokenProvider? _provider;
  final StreamController<FountisEvent> _events = StreamController<FountisEvent>.broadcast();

  Future<void> _quiet(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (_) {
      // Every failure is silent.
    }
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'tokenRequest':
        final id = call.arguments as String;
        final String? token;
        try {
          token = await _provider?.call();
        } catch (_) {
          // A throw means "could not tell who is signed in", not "signed out". Answering null here would make the
          // native SDK treat the person as a guest, so report a failure instead (nothing is shown).
          await _quiet('rejectToken', id);
          return null;
        }
        await _quiet('resolveToken', {'id': id, 'token': token});
      case 'event':
        final m = Map<Object?, Object?>.from(call.arguments as Map);
        _events.add(FountisEvent(m['type'] as String, m['offerId'] as String?));
    }
    return null;
  }

  @override
  Future<void> start({required String key, String? apiBase}) => _quiet('start', {'key': key, 'apiBase': apiBase});

  @override
  void setUserToken(FountisTokenProvider? provider) {
    _provider = provider;
    _quiet('setTokenProviderEnabled', provider != null);
  }

  @override
  Future<void> enableNotifications() => _quiet('enableNotifications');

  @override
  Future<FountisResult> show() async {
    try {
      return fountisResultFromName(await _channel.invokeMethod<String>('show'));
    } catch (_) {
      return FountisResult.noFill;
    }
  }

  @override
  Future<bool> handlePush(Map<String, dynamic> data) async {
    try {
      final strings = data.map((k, v) => MapEntry(k, '$v'));
      return await _channel.invokeMethod<bool>('handlePush', strings) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> setUserConsent(bool granted) => _quiet('setUserConsent', granted);

  @override
  Future<void> signOut() => _quiet('signOut');

  @override
  Stream<FountisEvent> get onEvent => _events.stream;
}
