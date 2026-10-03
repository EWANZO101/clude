import Ionicons from '@expo/vector-icons/Ionicons';
import { Tabs } from 'expo-router';
import type { ComponentProps } from 'react';
import type { ColorValue } from 'react-native';

import { colors } from '@/theme/theme';

type IconName = ComponentProps<typeof Ionicons>['name'];
const tab = (title: string, icon: IconName) => ({
  title,
  tabBarIcon: ({ color, size }: { color: ColorValue; size: number }) => <Ionicons name={icon} color={color as string} size={size} />,
});

export default function StudioTabs() {
  return (
    <Tabs
      screenOptions={{
        headerShown: false,
        tabBarActiveTintColor: colors.accent,
        tabBarInactiveTintColor: colors.textMuted,
        tabBarStyle: { backgroundColor: colors.surface, borderTopColor: colors.border },
      }}
    >
      <Tabs.Screen name="dashboard" options={tab('Studio', 'grid-outline')} />
      <Tabs.Screen name="all-orders" options={tab('Orders', 'list-outline')} />
      <Tabs.Screen name="tickets" options={tab('Tickets', 'chatbubbles-outline')} />
      <Tabs.Screen name="invoices" options={tab('Invoices', 'cash-outline')} />
    </Tabs>
  );
}
