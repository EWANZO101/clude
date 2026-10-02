import { useState } from 'react';
import { KeyboardAvoidingView, Platform, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';

import { Button, Row, Section, styles as ui } from '@/components/ui';
import { useAuth } from '@/lib/auth';
import { spacing, useColors } from '@/theme/colors';

export default function SignIn() {
  const colors = useColors();
  const { signIn } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function submit() {
    setSubmitting(true);
    setError(null);
    try {
      await signIn(email, password);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Sign in failed.');
      setSubmitting(false);
    }
  }

  const inputStyle = [ui.body, styles.input, { color: colors.label }];

  return (
    <KeyboardAvoidingView style={{ flex: 1, backgroundColor: colors.background }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
      <ScrollView contentContainerStyle={styles.container} keyboardShouldPersistTaps="handled">
        <View style={styles.header}>
          <Text style={[styles.title, { color: colors.label }]}>Scheduler</Text>
          <Text style={[ui.subhead, { color: colors.secondaryLabel, textAlign: 'center' }]}>
            Sign in with your Scheduler admin account.
          </Text>
        </View>

        <Section footer={error ?? undefined}>
          <Row>
            <TextInput
              style={inputStyle}
              placeholder="Email"
              placeholderTextColor={colors.tertiaryLabel}
              value={email}
              onChangeText={setEmail}
              autoCapitalize="none"
              autoComplete="email"
              keyboardType="email-address"
              textContentType="username"
              returnKeyType="next"
              accessibilityLabel="Email"
            />
          </Row>
          <Row last>
            <TextInput
              style={inputStyle}
              placeholder="Password"
              placeholderTextColor={colors.tertiaryLabel}
              value={password}
              onChangeText={setPassword}
              secureTextEntry
              autoComplete="current-password"
              textContentType="password"
              returnKeyType="go"
              onSubmitEditing={submit}
              accessibilityLabel="Password"
            />
          </Row>
        </Section>

        <View style={styles.button}>
          <Button title="Sign In" onPress={submit} loading={submitting} disabled={!email || !password} />
        </View>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  container: { flexGrow: 1, justifyContent: 'center', paddingVertical: spacing.xl * 2 },
  header: { alignItems: 'center', gap: spacing.sm, paddingHorizontal: spacing.xl },
  title: { fontSize: 34, fontWeight: '700' },
  input: { paddingVertical: 2 },
  button: { marginHorizontal: spacing.lg, marginTop: spacing.xl },
});
