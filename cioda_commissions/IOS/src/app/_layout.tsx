import { Cinzel_600SemiBold, Cinzel_700Bold, useFonts as useCinzel } from '@expo-google-fonts/cinzel';
import {
  CrimsonPro_400Regular,
  CrimsonPro_400Regular_Italic,
  CrimsonPro_600SemiBold,
  useFonts as useCrimson,
} from '@expo-google-fonts/crimson-pro';
import { router } from 'expo-router';
import { DarkTheme, ThemeProvider } from 'expo-router/react-navigation';
import { Stack } from 'expo-router/stack';
import * as SplashScreen from 'expo-splash-screen';
import { StatusBar } from 'expo-status-bar';
import { useEffect } from 'react';
import { Platform, Pressable, Text } from 'react-native';

import { useLastNotificationResponse } from '@/lib/push';
import { SessionProvider, useSession } from '@/lib/session';
import { colors, fonts } from '@/theme/theme';

SplashScreen.preventAutoHideAsync().catch(() => {});

const navTheme = {
  ...DarkTheme,
  colors: { ...DarkTheme.colors, primary: colors.accent, background: colors.background, card: colors.surface, text: colors.text, border: colors.border },
};

export function HeaderCancel() {
  return (
    <Pressable onPress={() => router.back()} hitSlop={8} accessibilityRole="button" style={Platform.OS === 'web' && { paddingHorizontal: 16 }}>
      <Text style={{ color: colors.accent, fontSize: 17 }}>Cancel</Text>
    </Pressable>
  );
}

/** Tapping a notification opens what it's about. */
function NotificationTaps({ isAdmin }: { isAdmin: boolean }) {
  const response = useLastNotificationResponse();
  useEffect(() => {
    const data = (response?.notification.request.content.data ?? {}) as Record<string, string>;
    if (isAdmin) {
      if (data.kind === 'ticket' && data.ticket_id) router.push(`/studio/ticket/${data.ticket_id}`);
      else if (data.kind === 'order' && data.order_id) router.push(`/studio/order/${data.order_id}`);
      else if (data.kind === 'requests') router.push('/studio/requests');
    } else if (data.link) {
      if (data.kind === 'ticket' && data.ticket_id) router.push(`/order/${data.link}/ticket/${data.ticket_id}`);
      else router.push(`/order/${data.link}`);
    }
  }, [response, isAdmin]);
  return null;
}

const headerOptions = {
  headerStyle: { backgroundColor: colors.surface },
  headerTintColor: colors.accent,
  headerTitleStyle: { fontFamily: fonts.displaySemi, color: colors.text },
  headerBackButtonDisplayMode: 'minimal' as const,
  contentStyle: { backgroundColor: colors.background },
};

function RootStack() {
  const { ready, admin } = useSession();
  const [cinzel] = useCinzel({ Cinzel_600SemiBold, Cinzel_700Bold });
  const [crimson] = useCrimson({ CrimsonPro_400Regular, CrimsonPro_400Regular_Italic, CrimsonPro_600SemiBold });
  const loaded = ready && cinzel && crimson;

  useEffect(() => {
    if (loaded) SplashScreen.hideAsync().catch(() => {});
  }, [loaded]);

  if (!loaded) return null;
  const isAdmin = !!admin;

  return (
    <>
      <NotificationTaps isAdmin={isAdmin} />
      <Stack screenOptions={headerOptions}>
        <Stack.Protected guard={!isAdmin}>
          <Stack.Screen name="(shop)" options={{ headerShown: false }} />
          <Stack.Screen name="order/[link]/index" options={{ title: 'Your Order' }} />
          <Stack.Screen name="order/[link]/pin" options={{ title: 'Order PIN', presentation: 'modal', headerLeft: () => <HeaderCancel /> }} />
          <Stack.Screen name="order/[link]/new-ticket" options={{ title: 'Get Help', presentation: 'modal', headerLeft: () => <HeaderCancel /> }} />
          <Stack.Screen name="order/[link]/ticket/[id]" options={{ title: 'Support' }} />
          <Stack.Screen name="add-order" options={{ title: 'Add an Order', presentation: 'modal', headerLeft: () => <HeaderCancel /> }} />
          <Stack.Screen name="studio-login" options={{ title: 'Artist Sign In', presentation: 'modal', headerLeft: () => <HeaderCancel /> }} />
        </Stack.Protected>
        <Stack.Protected guard={isAdmin}>
          <Stack.Screen name="(studio)" options={{ headerShown: false }} />
          <Stack.Screen name="studio/order/[id]" options={{ title: 'Order' }} />
          <Stack.Screen name="studio/update/[id]" options={{ title: 'Post an Update', presentation: 'modal', headerLeft: () => <HeaderCancel /> }} />
          <Stack.Screen name="studio/ticket/[id]" options={{ title: 'Ticket' }} />
          <Stack.Screen name="studio/requests" options={{ title: 'Requests' }} />
        </Stack.Protected>
      </Stack>
    </>
  );
}

export default function RootLayout() {
  return (
    <ThemeProvider value={navTheme}>
      <SessionProvider>
        <RootStack />
        <StatusBar style="light" />
      </SessionProvider>
    </ThemeProvider>
  );
}
