import { useState } from 'react';
import { Text, View } from 'react-native';

import { Button, Field, Page, styles as ui } from '@/components/ui';
import { useSession } from '@/lib/session';
import { colors, spacing } from '@/theme/theme';

/** Cioda's sign-in: same username and password as the website's /admin. */
export default function StudioLogin() {
  const { signInAdmin } = useSession();
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit() {
    setBusy(true);
    setError(null);
    try {
      // On success the root layout swaps to the Studio tabs, which closes this sheet.
      await signInAdmin(username, password);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Sign in failed.');
      setBusy(false);
    }
  }

  return (
    <Page>
      <View style={{ padding: spacing.lg, gap: spacing.lg }}>
        <Text style={ui.bodySmall}>For Cioda only. Use the same username and password as the website’s admin panel.</Text>
        <Field label="Username" value={username} onChangeText={setUsername} autoCapitalize="none" autoCorrect={false} textContentType="username" autoFocus />
        <Field
          label="Password"
          value={password}
          onChangeText={setPassword}
          secureTextEntry
          textContentType="password"
          returnKeyType="go"
          onSubmitEditing={submit}
        />
        {error && <Text style={{ color: colors.danger, fontSize: 15 }}>{error}</Text>}
        <Button title="Sign In" onPress={submit} loading={busy} disabled={!username || !password} />
      </View>
    </Page>
  );
}
