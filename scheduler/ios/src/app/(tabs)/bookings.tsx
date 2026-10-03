import { useEffect, useRef, useState } from 'react';
import { Text } from 'react-native';

import { BookingRow } from '@/components/booking-row';
import { LoadingState, MessageState, Row, Screen, Section, Segmented, styles as ui } from '@/components/ui';
import type { BookingFilter } from '@/lib/api';
import { useApi } from '@/lib/auth';
import { useApiData } from '@/lib/use-api-data';
import { useColors } from '@/theme/colors';

const FILTERS: { value: BookingFilter; label: string }[] = [
  { value: 'upcoming', label: 'Upcoming' },
  { value: 'past', label: 'Past' },
  { value: 'cancelled', label: 'Cancelled' },
  { value: 'all', label: 'All' },
];

const EMPTY: Record<BookingFilter, string> = {
  upcoming: 'No upcoming bookings.',
  past: 'No past bookings.',
  cancelled: 'No cancelled bookings.',
  all: 'No bookings yet.',
};

export default function Bookings() {
  const colors = useColors();
  const api = useApi();
  const [filter, setFilter] = useState<BookingFilter>('upcoming');
  const { data, setData, error, refreshing, refresh, reload } = useApiData(() => api.bookings(filter));

  // The focus effect in useApiData does the first load; this only handles filter changes.
  const firstRender = useRef(true);
  useEffect(() => {
    if (firstRender.current) {
      firstRender.current = false;
      return;
    }
    setData(null);
    reload();
  }, [filter, reload, setData]);

  const bookings = data?.bookings;

  return (
    <Screen title="Bookings" refreshing={refreshing} onRefresh={refresh}>
      <Segmented options={FILTERS} value={filter} onChange={setFilter} />
      {error && !bookings ? (
        <MessageState message={error} onRetry={reload} />
      ) : !bookings ? (
        <LoadingState />
      ) : (
        <Section footer={bookings.length === 200 ? 'Showing the 200 most recent.' : undefined}>
          {bookings.length === 0 ? (
            <Row last>
              <Text style={[ui.body, { color: colors.secondaryLabel }]}>{EMPTY[filter]}</Text>
            </Row>
          ) : (
            bookings.map((b, i) => <BookingRow key={b.id} booking={b} last={i === bookings.length - 1} />)
          )}
        </Section>
      )}
    </Screen>
  );
}
