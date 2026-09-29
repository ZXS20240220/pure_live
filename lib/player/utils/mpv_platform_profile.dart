import 'package:flutter/foundation.dart';
import 'package:pure_live/player/utils/player_consts.dart';

const Map<String, String> _iosVideoOutputDrivers = <String, String>{'libmpv': 'libmpv'};
const Map<String, String> _iosAudioOutputDrivers = <String, String>{
  'auto': 'auto',
  'audiounit': 'audiounit (iOS only)',
  'null': 'null (No audio output)',
};
const Map<String, String> _androidAudioOutputDrivers = <String, String>{
  'auto': 'auto (Automatic fallback)',
  'audiotrack': 'audiotrack (Android AudioTrack)',
  'aaudio': 'aaudio (Android 8.0+)',
  'opensles': 'opensles (Legacy fallback)',
  'null': 'null (No audio output)',
};
const Map<String, String> _iosHardwareDecoders = <String, String>{
  'auto': 'auto',
  'auto-safe': 'auto-safe',
  'auto-copy': 'auto-copy',
  'no': 'no',
  'videotoolbox': 'videotoolbox',
  'videotoolbox-copy': 'videotoolbox-copy',
};

/// Desktop embedders draw through the libmpv render API only. `gpu`/`sdl` and
/// the platform-specific X11/Direct3D VOs are compiled (if at all) as
/// standalone window outputs and cannot feed media_kit's Flutter texture.
const Map<String, String> _desktopEmbeddedVideoOutputDrivers = <String, String>{'libmpv': 'libmpv', 'null': 'null'};

/// The shipped Windows libmpv only contains WASAPI (plus null/pcm helpers).
/// directsound/winmm/openal are not compiled, so exposing them here would end
/// in "Audio output ... not found" and silence.
const Map<String, String> _windowsAudioOutputDrivers = <String, String>{
  'auto': 'auto (Automatic fallback)',
  'wasapi': 'wasapi (Windows WASAPI)',
  'null': 'null (No audio output)',
};

/// Returns only native MPV outputs that the current settings UI may persist.
///
/// media_kit owns the iOS Flutter texture through `vo=libmpv`. Android exposes
/// only drivers compiled into the bundled libmpv instead of mixing Windows and
/// Linux choices into the phone settings menu.
Map<String, String> mpvVideoOutputDriversForPlatform(TargetPlatform platform) => switch (platform) {
  TargetPlatform.iOS => _iosVideoOutputDrivers,
  TargetPlatform.android => PlayerConsts.videoOutputDrivers,
  _ => _desktopEmbeddedVideoOutputDrivers,
};

Map<String, String> mpvAudioOutputDriversForPlatform(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android => _androidAudioOutputDrivers,
  TargetPlatform.iOS => _iosAudioOutputDrivers,
  TargetPlatform.windows => _windowsAudioOutputDrivers,
  _ => PlayerConsts.audioOutputDrivers,
};

Map<String, String> mpvHardwareDecodersForPlatform(TargetPlatform platform) =>
    platform == TargetPlatform.iOS ? _iosHardwareDecoders : PlayerConsts.hardwareDecoder;

/// Android renders through its own Surface (`vo=gpu`); every other embedder
/// (Windows/macOS/Linux/iOS) keeps video inside the app via `vo=libmpv`.
/// Default VO used for fresh installs and "Reset".
String defaultMpvVideoOutputDriverForPlatform(TargetPlatform platform) =>
    platform == TargetPlatform.android ? 'gpu' : 'libmpv';

/// Validates a stored VO against the platform's embedded set.
///
/// Desktop only allows `libmpv` (Flutter texture via render API) and `null`
/// (explicit no-video). Legacy values from before this contract (`gpu`,
/// `gpu-next`, `direct3d`, `sdl`, ...) all failed embedded rendering by
/// spawning a standalone mpv window, so they migrate straight to `libmpv`.
String normalizeMpvVideoOutputDriverForPlatform(String value, TargetPlatform platform) => _normalizeMpvOption(
  value,
  mpvVideoOutputDriversForPlatform(platform),
  defaultMpvVideoOutputDriverForPlatform(platform),
);

String normalizeMpvAudioOutputDriverForPlatform(String value, TargetPlatform platform) =>
    _normalizeMpvOption(value, mpvAudioOutputDriversForPlatform(platform), 'auto');

/// Native audio preference applied when expert output overrides are disabled.
///
/// The bundled Android libmpv contains all three drivers. Prefer AudioTrack's
/// platform mixer path, retain AAudio and OpenSL ES as ordered fallbacks, then
/// let mpv probe any remaining compiled driver. Linux retains the existing
/// explicit ALSA default; other platforms keep media_kit's native default.
String? defaultMpvAudioOutputDriverForPlatform(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android => 'audiotrack,aaudio,opensles,',
  TargetPlatform.linux => 'alsa',
  _ => null,
};

/// Resolves the value sent to libmpv after applying the platform contract.
///
/// `auto` is not a registered AO driver in libmpv (it only has special meaning
/// for `--audio-device`), so sending `--ao=auto` fails audio initialization.
/// Resolve it to the platform's native default instead: the Android verified
/// fallback chain, explicit ALSA on Linux, or no `ao` property at all on
/// Windows/macOS so libmpv can autoprobe (WASAPI/CoreAudio).
String? effectiveMpvAudioOutputDriverForPlatform({
  required bool customOutput,
  required String configuredDriver,
  required TargetPlatform platform,
}) {
  if (!customOutput) return defaultMpvAudioOutputDriverForPlatform(platform);
  final normalized = normalizeMpvAudioOutputDriverForPlatform(configuredDriver, platform);
  if (normalized == 'auto') {
    return defaultMpvAudioOutputDriverForPlatform(platform);
  }
  return normalized;
}

bool isMpvAudioOutputDisabledForPlatform({
  required bool customOutput,
  required String configuredDriver,
  required TargetPlatform platform,
}) => customOutput && normalizeMpvAudioOutputDriverForPlatform(configuredDriver, platform) == 'null';

String normalizeMpvHardwareDecoderForPlatform(String value, TargetPlatform platform) =>
    _normalizeMpvOption(value, mpvHardwareDecodersForPlatform(platform), 'auto');

String _normalizeMpvOption(String value, Map<String, String> available, String fallback) =>
    available.containsKey(value) ? value : fallback;
