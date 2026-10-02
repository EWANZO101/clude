import Ionicons from '@expo/vector-icons/Ionicons';
import { Tabs } from 'expo-router';
import type { ComponentProps } from 'react';
import type { ColorValue } from 'react-native';

// Web-only stand-in for NativeTabs (see _layout.tsx), used by the browser preview.
type IconName = ComponentProps<typeof Ionicons>['name'];

const tab = (title: string, icon: IconName) => ({
  title,
  tabBarIcon: ({ color, size }: { color: ColorValue; size: number }) => <Ionicons name={icon} color={color as string} size={size} />,
});

export default function TabsLayout() {
  return (
    <Tabs screenOptions={{ headerShown: false }}>
      <Tabs.Screen name="index" options={tab('Today', 'sunny-outline')} />
      <Tabs.Screen name="bookings" options={tab('Bookings', 'list-outline')} />
      <Tabs.Screen name="calendar" options={tab('Calendar', 'calendar-outline')} />
      <Tabs.Screen name="time-off" options={tab('Time Off', 'airplane-outline')} />
    </Tabs>
  );
}
