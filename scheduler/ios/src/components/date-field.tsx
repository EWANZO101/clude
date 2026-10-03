import DateTimePicker, { DateTimePickerAndroid } from '@react-native-community/datetimepicker';
import { Platform, Pressable, Text } from 'react-native';

import { styles } from '@/components/ui';
import { toDateString, toTimeString } from '@/lib/format';
import { useColors } from '@/theme/colors';

type Props = { mode: 'date' | 'time'; value: Date; onChange: (value: Date) => void; accessibilityLabel: string };

/** iOS: the inline "compact" pill picker. Android: a button that opens the system dialog. */
export function DateField({ mode, value, onChange, accessibilityLabel }: Props) {
  const colors = useColors();

  if (Platform.OS === 'ios') {
    return (
      <DateTimePicker
        mode={mode}
        value={value}
        display="compact"
        minuteInterval={mode === 'time' ? 5 : undefined}
        accentColor={colors.tint}
        onChange={(_, date) => date && onChange(date)}
        accessibilityLabel={accessibilityLabel}
      />
    );
  }

  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
      onPress={() =>
        DateTimePickerAndroid.open({ mode, value, is24Hour: true, onChange: (_, date) => date && onChange(date) })
      }
    >
      <Text style={[styles.body, { color: colors.tint }]}>{mode === 'date' ? toDateString(value) : toTimeString(value)}</Text>
    </Pressable>
  );
}
