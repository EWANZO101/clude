import { NativeTabs } from 'expo-router/unstable-native-tabs';

import { colors } from '@/theme/theme';

export default function ShopTabs() {
  return (
    <NativeTabs tintColor={colors.accent}>
      <NativeTabs.Trigger name="index">
        <NativeTabs.Trigger.Icon sf="sparkles" md="auto_awesome" />
        <NativeTabs.Trigger.Label>Home</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
      <NativeTabs.Trigger name="request">
        <NativeTabs.Trigger.Icon sf="paintbrush.pointed" md="brush" />
        <NativeTabs.Trigger.Label>Request</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
      <NativeTabs.Trigger name="orders">
        <NativeTabs.Trigger.Icon sf="shippingbox" md="inventory_2" />
        <NativeTabs.Trigger.Label>My Orders</NativeTabs.Trigger.Label>
      </NativeTabs.Trigger>
    </NativeTabs>
  );
}
