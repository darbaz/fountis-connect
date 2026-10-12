import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fountis_connect_platform_interface/fountis_connect_platform_interface.dart';

const _channelName = 'org.fountis.connect/methods';
const _channel = MethodChannel(_channelName);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late MethodChannelFountisConnect plugin;
  late List<MethodCall> sent;

  /// Everything the plugin sent to "native" except the setup call.
  List<MethodCall> answers() => sent.where((c) => c.method != 'setTokenProviderEnabled').toList();

  /// Plays the native side asking Dart for a token, and waits until Dart has answered.
  Future<void> nativeAsks(String id) {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      _channelName,
      const StandardMethodCodec().encodeMethodCall(MethodCall('tokenRequest', id)),
      (_) => done.complete(),
    );
    return done.future;
  }

  setUp(() {
    sent = [];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      sent.add(call);
      return null;
    });
    plugin = MethodChannelFountisConnect();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    _channel.setMethodCallHandler(null);
  });

  test('a token is passed on with resolveToken', () async {
    plugin.setUserToken(() async => 'tok');
    await nativeAsks('r1');

    expect(answers().map((c) => c.method), ['resolveToken']);
    expect(answers().single.arguments, {'id': 'r1', 'token': 'tok'});
  });

  test('null (nobody is signed in) is still an answer, sent with resolveToken', () async {
    plugin.setUserToken(() async => null);
    await nativeAsks('r1');

    expect(answers().map((c) => c.method), ['resolveToken']);
    expect(answers().single.arguments, {'id': 'r1', 'token': null});
  });

  test('a provider that throws synchronously sends rejectToken, never resolveToken', () async {
    plugin.setUserToken(() => throw StateError('endpoint down'));
    await nativeAsks('r1');

    expect(answers().map((c) => c.method), ['rejectToken']);
    expect(answers().single.arguments, 'r1');
  });

  test('a provider that returns a failed future sends rejectToken, never resolveToken', () async {
    plugin.setUserToken(() => Future<String?>.error(StateError('endpoint down')));
    await nativeAsks('r1');

    expect(answers().map((c) => c.method), ['rejectToken']);
    expect(answers().single.arguments, 'r1');
  });

  test('an older native plugin that does not know rejectToken changes nothing for Dart', () async {
    messenger.setMockMethodCallHandler(_channel, (call) async {
      sent.add(call);
      if (call.method == 'rejectToken') throw MissingPluginException();
      return null;
    });
    plugin.setUserToken(() async => throw StateError('endpoint down'));

    await nativeAsks('r1'); // completes without an error

    expect(answers().map((c) => c.method), ['rejectToken']);
  });
}
