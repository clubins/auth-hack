/// Pure formatting helpers for the UI — no Flutter imports, so they unit
/// test trivially.
library;

/// Renders a timestamp in the user's local time as `yyyy-MM-dd HH:mm`.
/// No intl dependency: the fixed-width form is the entire contract.
String formatTimestamp(DateTime value) {
  final local = value.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// Renders a temperature reading as `21 °C` or `21.5 °C` — integral
/// values print without a decimal point.
String formatTemperature(num temperatureC) {
  final value = temperatureC.toDouble();
  final text =
      value == value.roundToDouble() ? value.round().toString() : '$value';
  return '$text °C';
}
