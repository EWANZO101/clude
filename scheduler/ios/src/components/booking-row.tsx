import { router } from 'expo-router';
import { Text, View } from 'react-native';

import { Pill, Row, styles } from '@/components/ui';
import type { Booking } from '@/lib/api';
import { capitalize, formatDay, formatRange } from '@/lib/format';
import { bookingStatusColor, useColors } from '@/theme/colors';

export function BookingRow({ booking, showDate = true, last }: { booking: Booking; showDate?: boolean; last?: boolean }) {
  const colors = useColors();
  const showStatus = booking.status !== 'confirmed';
  return (
    <Row onPress={() => router.push(`/booking/${booking.id}`)} last={last}>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
        <View style={{ flex: 1, gap: 2 }}>
          <Text style={[styles.body, { color: colors.label, fontWeight: '600' }]} numberOfLines={1}>
            {booking.name}
          </Text>
          <Text style={[styles.subhead, { color: colors.secondaryLabel }]} numberOfLines={1}>
            {showDate ? `${formatDay(booking.start)} · ` : ''}
            {formatRange(booking.start, booking.end)}
            {booking.booking_type ? ` · ${booking.booking_type}` : ''}
          </Text>
          {/* Badges sit under the text so they never squeeze the time off the row. */}
          {(showStatus || booking.is_out_of_hours) && (
            <View style={{ flexDirection: 'row', gap: 6, marginTop: 4 }}>
              {showStatus && <Pill label={capitalize(booking.status)} color={bookingStatusColor(colors, booking.status)} />}
              {booking.is_out_of_hours && <Pill label="Out of hours" color={colors.orange} />}
            </View>
          )}
        </View>
        <Text style={{ color: colors.tertiaryLabel, fontSize: 20 }}>›</Text>
      </View>
    </Row>
  );
}
