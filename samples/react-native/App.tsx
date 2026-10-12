import { useEffect, useState } from 'react';
import { Button, SafeAreaView, ScrollView, Text, View } from 'react-native';
import * as Fountis from '@fountispanel/connect-react-native';

// Sandbox only: an unsigned token (alg "none") for a made-up user. Your real app asks its own server
// for a signed token (see ../server-node). Set PARTNER_ID / APP_ID to the ids from the FOUNTIS console.
const PARTNER_ID = 'ptn_REPLACE_ME';
const APP_ID = 'app_REPLACE_ME';

const b64 = (o: object) =>
  btoa(JSON.stringify(o)).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');

function sandboxToken(): string {
  const iat = Math.floor(Date.now() / 1000);
  return (
    b64({ alg: 'none', typ: 'JWT' }) + '.' +
    b64({
      iss: PARTNER_ID,
      aud: `fountis-connect:${APP_ID}`,
      sub: 'sandbox_user_0001_AAAAAAAAAAAAAAAA',
      kyc: 'verified',
      attrs: { gender: 'female', birth_year: new Date().getFullYear() - 33, governorate: 'erbil', city: 'erbil', lang: 'en' },
      mapping_version: 1,
      iat,
      exp: iat + 3600,
      jti: Math.random().toString(36).slice(2),
    }) + '.'
  );
}

export default function App() {
  const [log, setLog] = useState<string[]>([]);
  const add = (m: string) => setLog((l) => [m, ...l].slice(0, 30));

  useEffect(() => {
    Fountis.start({ key: 'pk_test_REPLACE_ME' });
    Fountis.setUserToken(async () => sandboxToken());
    const off = Fountis.onEvent((e) => add(JSON.stringify(e)));
    return off;
  }, []);

  return (
    <SafeAreaView style={{ flex: 1 }}>
      <View style={{ padding: 20, gap: 12 }}>
        <Text style={{ fontSize: 22, fontWeight: '700' }}>FOUNTIS Connect sample</Text>
        <Button title="Show a study" onPress={async () => add('show() -> ' + (await Fountis.show()))} />
        <Button title="Turn on notifications" onPress={() => Fountis.enableNotifications()} />
        <Button title="Sign out" onPress={() => Fountis.signOut()} />
      </View>
      <ScrollView contentContainerStyle={{ padding: 20 }}>
        {log.map((l, i) => (
          <Text key={i} style={{ fontFamily: 'Courier', fontSize: 12 }}>{l}</Text>
        ))}
      </ScrollView>
    </SafeAreaView>
  );
}
