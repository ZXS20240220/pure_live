import '../core/barrage_config.dart';
import '../model/barrage/barrage_track.dart';
import '../model/barrage/barrage_entry.dart';

class TrackAllocator {
  const TrackAllocator();

  int allocate({
    required List<BarrageTrack> tracks,
    required BarrageEntry current,
    required double screenWidth,
    required BarrageConfig config,
  }) {
    if (tracks.isEmpty) return -1;

    int bestTrack = -1;
    double minPenalty = double.infinity;

    // Overlap preset fallback: when every unlocked lane violates the safe gap,
    // share the least-busy lane instead of dropping the item.
    int overlapTrack = -1;
    double minOverlapPenalty = double.infinity;

    final int len = tracks.length;
    for (int i = 0; i < len; i++) {
      final track = tracks[i];
      if (track.locked) continue;

      if (track.activeCount == 0) {
        return i;
      }

      final double penalty = track.activeCount * 10.0 + track.avgSpeed * 0.1;
      if (config.allowOverlap && penalty < minOverlapPenalty) {
        minOverlapPenalty = penalty;
        overlapTrack = i;
      }

      final last = track.lastEntry;
      if (last != null) {
        if (last.x + last.width + config.overlapSafeGap > screenWidth) {
          continue;
        }
      }

      if (penalty < minPenalty) {
        minPenalty = penalty;
        bestTrack = i;
      }
    }

    if (bestTrack != -1) return bestTrack;
    return overlapTrack;
  }
}
