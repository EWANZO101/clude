import { NativeTabs } from 'expo-router/unstable-native-tabs';

import { colors } from '@/theme/theme';

export default function StudioTabs() {
  return (
    <NativeTabs tintColor={colors.accent}>
      <NativeTabs.Trigger name="dashboard">
        <NativeTabs.Trigger.Icon sf="square.grid.2x2" md="dashboard" />
        <NativeTabs.Trigger.Label>Studio</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
      <NativeTabs.Trigger name="all-orders">
        <NativeTabs.Trigger.Icon sf="list.bullet.rectangle" md="list" />
        <NativeTabs.Trigger.Label>Orders</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
      <NativeTabs.Trigger name="tickets">
        <NativeTabs.Trigger.Icon sf="bubble.left.and.bubble.right" md="forum" />
        <NativeTabs.Trigger.Label>Tickets</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
      <NativeTabs.Trigger name="invoices">
        <NativeTabs.Trigger.Icon sf="dollarsign.circle" md="payments" />
        <NativeTabs.Trigger.Label>Invoices</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
    </NativeTabs>
  );
}
