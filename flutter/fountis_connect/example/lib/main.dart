import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fountis_connect/fountis_connect.dart';

// Sandbox only: an unsigned token (alg "none") for a made-up user. Your real app asks its own server
// for a signed token (see ../../../samples/server-node). Use the ids from the FOUNTIS console.
const _key = 'pk_test_REPLACE_ME';
const _partnerId = 'ptn_REPLACE_ME';
const _appId = 'app_REPLACE_ME';

String _b64(Map<String, Object?> o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');

Future<String?> sandboxToken() async {
  final iat = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${_b64({'alg': 'none', 'typ': 'JWT'})}.${_b64({
        'iss': _partnerId,
        'aud': 'fountis-connect:$_appId',
        'sub': 'sandbox_user_0001_AAAAAAAAAAAAAAAA',
        'kyc': 'verified',
        'attrs': {'gender': 'female', 'birth_year': DateTime.now().year - 33, 'governorate': 'erbil', 'city': 'erbil', 'lang': 'en'},
        'mapping_version': 1,
        'iat': iat,
        'exp': iat + 3600,
        'jti': '$iat',
      })}.';
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FountisConnect.start(key: _key);
  FountisConnect.setUserToken(sandboxToken);
  runApp(const SampleApp());
}

class SampleApp extends StatefulWidget {
  const SampleApp({super.key});

  @override
  State<SampleApp> createState() => _SampleAppState();
}

class _SampleAppState extends State<SampleApp> {
  final List<String> _log = [];

  @override
  void initState() {
    super.initState();
    FountisConnect.onEvent.listen((e) => _add(e.toString()));
  }

  void _add(String line) => setState(() => _log.insert(0, line));

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('FOUNTIS Connect sample')),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                onPressed: () async => _add('show() -> ${(await FountisConnect.show()).name}'),
                child: const Text('Show a study'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: FountisConnect.enableNotifications, child: const Text('Turn on notifications')),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: FountisConnect.signOut, child: const Text('Sign out')),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  children: [for (final l in _log) Text(l, style: const TextStyle(fontFamily: 'Courier', fontSize: 12))],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
