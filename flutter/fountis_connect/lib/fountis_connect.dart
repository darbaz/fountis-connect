/// FOUNTIS Connect for Flutter. Same API names as the native, web and React Native SDKs:
/// start, setUserToken, enableNotifications, show, handlePush, setUserConsent, signOut, onEvent.
///
/// ```dart
/// await FountisConnect.start(key: 'pk_live_...');
/// FountisConnect.setUserToken(() async => await myServer.fountisToken()); // null only when signed out; throw on failure
/// final result = await FountisConnect.show(); // FountisResult.noFill / dismissed / completed
/// ```
library;

import 'package:fountis_connect_platform_interface/fountis_connect_platform_interface.dart';

export 'package:fountis_connect_platform_interface/fountis_connect_platform_interface.dart'
    show FountisResult, FountisEvent, FountisTokenProvider;

class FountisConnect {
  FountisConnect._();

  static FountisConnectPlatform get _p => FountisConnectPlatform.instance;

  /// Starts the SDK. Call once, early (for example in `main`). [apiBase] is only for testing.
  static Future<void> start({required String key, String? apiBase}) => _p.start(key: key, apiBase: apiBase);

  /// Gives the SDK a way to get the signed user token from your server. Return the token when someone is signed in,
  /// and null only when nobody is signed in. Throw when you cannot get one (for example your token endpoint failed):
  /// nothing is shown, and the person is never treated as a guest. No answer within 10 seconds also counts as a failure.
  /// Called when the SDK needs a token; it is not stored.
  /// When it returns null and FOUNTIS has switched guests on for your app (adult-only apps only), the SDK offers the
  /// free studies marked open to guests, after an 18+ confirmation. An app without accounts can pass `() async => null`.
  static void setUserToken(FountisTokenProvider provider) => _p.setUserToken(provider);

  /// Turns on the background check and asks for the notification permission. One notification a day at most.
  static Future<void> enableNotifications() => _p.enableNotifications();

  /// Looks for a matching study and shows it full screen. Completes when the person is done.
  /// [FountisResult.noFill] comes back fast when there is nothing to show.
  static Future<FountisResult> show() => _p.show();

  /// Call from your push handler with the message data. True if it was a FOUNTIS push (it has a `fountis` key).
  static Future<bool> handlePush(Map<String, dynamic> data) => _p.handlePush(data);

  /// Your own consent switch. Default true.
  static Future<void> setUserConsent(bool granted) => _p.setUserConsent(granted);

  /// Forgets the signed-in person on this device.
  static Future<void> signOut() => _p.signOut();

  /// Anonymous lifecycle events: shown, dismissed, completed, noFill, notified.
  static Stream<FountisEvent> get onEvent => _p.onEvent;
}
