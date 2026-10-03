import { DarkTheme, DefaultTheme, ThemeProvider } from 'expo-router/react-navigation';
import { Stack } from 'expo-router/stack';
import { StatusBar } from 'expo-status-bar';
import { router } from 'expo-router';
import { useEffect } from 'react';
import { Platform, Pressable, Text, useColorScheme, View } from 'react-native';

import { AuthProvider, useAuth } from '@/lib/auth';
import { openSettingsOnFirstLaunch } from '@/lib/first-launch';
import { useNotificationTaps } from '@/lib/push';
import { useColors } from '@/theme/colors';

function HeaderCancel() {
  const colors = useColors();
  return (
    // The native iOS header spaces its buttons itself; the web header doesn't.
    <Pressable onPress={() => router.back()} accessibilityRole="button" hitSlop={8} style={Platform.OS === 'web' && { paddingHorizontal: 16 }}>
      <Text style={{ color: colors.tint, fontSize: 17 }}>Cancel</Text>
    </Pressable>
  );
}

function NotificationTaps() {
  useNotificationTaps();
  return null;
}

function RootStack() {
  const { loading, user } = useAuth();
  const colors = useColors();

  // First launch only: open the website's Settings (via its sign-in) once
  // the app has finished checking for a saved session.
  useEffect(() => {
    if (!loading) openSettingsOnFirstLaunch();
  }, [loading]);

  // Hold on a blank screen while the saved token is checked, so a signed-in
  // user never sees the sign-in screen flash up first.
  if (loading) return <View style={{ flex: 1, backgroundColor: colors.background }} />;

  return (
    <>
    {/* Only once signed in, so a tap on a booking notification can open the booking. */}
    {user && <NotificationTaps />}
    <Stack screenOptions={{ headerBackButtonDisplayMode: 'minimal' }}>
      <Stack.Protected guard={!!user}>
        <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
        <Stack.Screen name="booking/[id]" options={{ title: 'Booking' }} />
        <Stack.Screen
          name="time-off-new"
          options={{
            title: 'Add Time Off',
            // A full modal with a real header, like Calendar's "New Event" — a
            // detented formSheet with a header and a ScrollView laid out badly.
            presentation: 'modal',
            headerLeft: () => <HeaderCancel />,
          }}
        />
      </Stack.Protected>
      <Stack.Protected guard={!user}>
        <Stack.Screen name="sign-in" options={{ headerShown: false }} />
      </Stack.Protected>
    </Stack>
    </>
  );
}

export default function RootLayout() {
  const scheme = useColorScheme();
  return (
    <ThemeProvider value={scheme === 'dark' ? DarkTheme : DefaultTheme}>
      <AuthProvider>
        <RootStack />
        <StatusBar style="auto" />
      </AuthProvider>
    </ThemeProvider>
  );
}
