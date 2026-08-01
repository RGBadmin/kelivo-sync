/// Hybrid-logical-clock-lite timestamp source for sync LWW ordering.
///
/// Issued timestamps are strictly monotonic within a process and never lag
/// behind any remote timestamp observed during a pull, so a device with a
/// slow wall clock cannot silently lose every conflict. Timestamps are
/// microseconds since epoch (UTC) and remain comparable with the
/// `updated_at` values the app already writes.
abstract final class SyncClock {
  static int _floor = 0;

  /// Returns the next LWW timestamp: `max(wall clock, last issued + 1,
  /// max observed remote + 1)`.
  static int nowMicros() {
    final wall = DateTime.now().toUtc().microsecondsSinceEpoch;
    final issued = wall > _floor ? wall : _floor + 1;
    _floor = issued;
    return issued;
  }

  /// Feeds a timestamp observed from the remote (or from local persistence
  /// at startup) into the clock so subsequently issued timestamps stay
  /// above it.
  static void observe(int micros) {
    if (micros > _floor) _floor = micros;
  }

  /// True when the wall clock lags more than [tolerance] behind the clock
  /// floor, which usually means this device's clock is set wrong.
  static bool wallClockLooksSkewed({
    Duration tolerance = const Duration(minutes: 5),
  }) {
    final wall = DateTime.now().toUtc().microsecondsSinceEpoch;
    return _floor - wall > tolerance.inMicroseconds;
  }

  /// Test hook: resets the clock floor.
  static void resetForTest([int floor = 0]) {
    _floor = floor;
  }
}
