import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:fountis_connect_platform_interface/fountis_connect_platform_interface.dart';
import 'package:web/web.dart' as web;

/// Web implementation: calls the Web SDK (`connect.js`, global `FountisConnect`).
///
/// Add the script to `web/index.html`:
/// `<script src="https://cdn.fountis.org/connect/1.1.0/connect.js"></script>`
/// If it is missing, this plugin loads it from [scriptUrl] on first use.
class FountisConnectWeb extends FountisConnectPlatform {
  static void registerWith(Registrar registrar) {
    FountisConnectPlatform.instance = FountisConnectWeb();
  }

  /// Where the Web SDK is loaded from when the page did not include it.
  static String scriptUrl = 'https://cdn.fountis.org/connect/1.1.0/connect.js';

  final StreamController<FountisEvent> _events = StreamController<FountisEvent>.broadcast();
  Future<JSObject?>? _loading;
  bool _listening = false;

  JSObject? get _global {
    final v = globalContext.getProperty<JSAny?>('FountisConnect'.toJS);
    return v.isA<JSObject>() ? v as JSObject : null;
  }

  /// The Web SDK object, loading the script if needed. Null when it cannot be loaded; nothing throws.
  Future<JSObject?> _sdk() => _loading ??= _load();

  Future<JSObject?> _load() async {
    try {
      var sdk = _global;
      if (sdk == null) {
        final done = Completer<void>();
        final script = web.HTMLScriptElement()
          ..src = scriptUrl
          ..async = true;
        script.onload = ((web.Event _) => done.complete()).toJS;
        script.onerror = ((web.Event _) => done.complete()).toJS;
        web.document.head!.append(script);
        await done.future;
        sdk = _global;
      }
      if (sdk != null && !_listening) {
        _listening = true;
        sdk.callMethod<JSAny?>(
          'onEvent'.toJS,
          ((JSObject e) {
            final type = e.getProperty<JSAny?>('type'.toJS);
            final offer = e.getProperty<JSAny?>('offerId'.toJS);
            if (type.isA<JSString>()) {
              _events.add(FountisEvent((type as JSString).toDart, offer.isA<JSString>() ? (offer as JSString).toDart : null));
            }
          }).toJS,
        );
      }
      return sdk;
    } catch (_) {
      return null;
    }
  }

  Future<void> _call(String method, [JSAny? arg]) async {
    try {
      final sdk = await _sdk();
      if (sdk == null) return;
      if (arg == null) {
        sdk.callMethod<JSAny?>(method.toJS);
      } else {
        sdk.callMethod<JSAny?>(method.toJS, arg);
      }
    } catch (_) {
      // Every failure is silent.
    }
  }

  @override
  Future<void> start({required String key, String? apiBase}) {
    final opts = JSObject()..['key'] = key.toJS;
    if (apiBase != null) opts['apiBase'] = apiBase.toJS;
    return _call('start', opts);
  }

  @override
  void setUserToken(FountisTokenProvider? provider) {
    final JSAny fn = ((() => (provider?.call() ?? Future<String?>.value()).then<JSAny?>((v) => v?.toJS).toJS).toJS);
    _call('setUserToken', fn);
  }

  @override
  Future<void> enableNotifications() => _call('enableNotifications');

  @override
  Future<FountisResult> show() async {
    try {
      final sdk = await _sdk();
      if (sdk == null) return FountisResult.noFill;
      final r = await (sdk.callMethod<JSPromise<JSAny?>>('show'.toJS)).toDart;
      return fountisResultFromName(r.isA<JSString>() ? (r as JSString).toDart : null);
    } catch (_) {
      return FountisResult.noFill;
    }
  }

  /// The web has no push messages.
  @override
  Future<bool> handlePush(Map<String, dynamic> data) async => false;

  @override
  Future<void> setUserConsent(bool granted) => _call('setUserConsent', granted.toJS);

  @override
  Future<void> signOut() => _call('signOut');

  @override
  Stream<FountisEvent> get onEvent {
    _sdk(); // attach the event listener
    return _events.stream;
  }
}
