import 'package:flutter_test/flutter_test.dart';
import 'package:flame_barrage/flame_barrage.dart';

void main() {
  const allocator = TrackAllocator();

  BarrageConfig config({bool allowOverlap = false, double safeGap = 40}) =>
      BarrageConfig(allowOverlap: allowOverlap, overlapSafeGap: safeGap);

  BarrageEntry entry({double x = 0, double width = 100, double speed = 100}) {
    final item = BarrageItem(content: 'test', type: BarrageType.scroll);
    return BarrageEntry(item: item, creationTime: 0)
      ..x = x
      ..width = width
      ..speed = speed
      ..track = 0;
  }

  test('returns -1 when every unlocked lane violates the safe gap and overlap is off', () {
    final tracks = [BarrageTrack(index: 0), BarrageTrack(index: 1)];
    tracks[0].lastEntry = entry(x: 500, width: 100)..track = 0;
    tracks[1].lastEntry = entry(x: 500, width: 100)..track = 1;

    // last.x + last.width + gap = 640 < 700, so a 700px screen still fits.
    expect(allocator.allocate(tracks: tracks, current: entry(), screenWidth: 700, config: config()), isNot(-1));

    // 610px screen: 500 + 100 + 40 > 610 for both lanes -> no allocation.
    expect(allocator.allocate(tracks: tracks, current: entry(), screenWidth: 610, config: config()), -1);
  });

  test('overlap preset falls back to the least-busy unlocked lane', () {
    final tracks = [BarrageTrack(index: 0), BarrageTrack(index: 1)];
    tracks[0].lastEntry = entry(x: 500, width: 100)..track = 0;
    tracks[0].activeCount = 3;
    tracks[1].lastEntry = entry(x: 500, width: 100)..track = 1;
    tracks[1].activeCount = 1;

    expect(
      allocator.allocate(tracks: tracks, current: entry(), screenWidth: 610, config: config(allowOverlap: true)),
      1,
    );
  });

  test('overlap preset never claims locked lanes and still prefers empty lanes', () {
    final tracks = [BarrageTrack(index: 0), BarrageTrack(index: 1)];
    tracks[0].locked = true;
    tracks[1].lastEntry = entry(x: 500, width: 100)..track = 1;

    expect(
      allocator.allocate(tracks: tracks, current: entry(), screenWidth: 610, config: config(allowOverlap: true)),
      1,
    );

    tracks[1].locked = true;
    expect(
      allocator.allocate(tracks: tracks, current: entry(), screenWidth: 610, config: config(allowOverlap: true)),
      -1,
    );
  });

  test('empty lanes win over the overlap fallback when both exist', () {
    final tracks = [BarrageTrack(index: 0), BarrageTrack(index: 1)];
    tracks[0].lastEntry = entry(x: 500, width: 100)..track = 0;

    expect(
      allocator.allocate(tracks: tracks, current: entry(), screenWidth: 610, config: config(allowOverlap: true)),
      1,
    );
  });

  test('BarrageConfig equality accounts for allowOverlap', () {
    expect(config(allowOverlap: true), config(allowOverlap: true));
    expect(config(allowOverlap: true), isNot(config(allowOverlap: false)));
  });
}
