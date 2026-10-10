import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:pure_live/modules/wallpaper/data/wallpaper_presets.dart';

/// 壁纸媒体种类
enum WallpaperKind { image, video, gradient }

/// 渐变色标
class WallpaperGradientStop {
  final String color;
  final double pos;

  const WallpaperGradientStop({required this.color, required this.pos});
}

/// 目录中的一个壁纸条目
///
/// 与应用壁纸用的 [WallpaperItem]（wallpaper_models.dart）不同，
/// 这里的条目描述目录中的媒体元数据，点击后才会转换为应用项。
class CatalogWallpaperItem {
  /// 图片/视频的绝对 URL，渐变时为合成键
  final String file;
  final String? id;
  final String? name;

  /// 视频海报
  final String? poster;

  /// 网格缩略图
  final String? thumb;

  /// 渐变 CSS 描述
  final String? css;

  /// 渐变角度（CSS 约定，0 指向上方，顺时针为正）
  final int deg;
  final List<WallpaperGradientStop>? gradient;

  const CatalogWallpaperItem({
    required this.file,
    this.id,
    this.name,
    this.poster,
    this.thumb,
    this.css,
    this.deg = 0,
    this.gradient,
  });

  String get key => file.isNotEmpty ? file : 'item:${id ?? name ?? css ?? ''}';
}

/// 图源中的一个分组
class CatalogWallpaperGroup {
  final String id;
  final String sourceId;
  final String apiQuery;
  final int count;
  final bool hidden;

  const CatalogWallpaperGroup({
    required this.id,
    required this.sourceId,
    required this.count,
    this.apiQuery = '',
    this.hidden = false,
  });
}

/// 顶层图源
class CatalogWallpaperSource {
  final String id;
  final WallpaperKind kind;
  final bool categorized;
  final int count;
  final List<CatalogWallpaperGroup> groups;

  const CatalogWallpaperSource({
    required this.id,
    required this.kind,
    required this.categorized,
    required this.groups,
    this.count = 0,
  });

  List<CatalogWallpaperGroup> get visibleGroups {
    if (!categorized) {
      final hiddenOnes = groups.where((group) => group.hidden).toList(growable: false);
      return hiddenOnes.isNotEmpty ? hiddenOnes : groups;
    }
    return groups.where((group) => group.count > 0).toList(growable: false);
  }
}

/// 图源 ID 常量
class WallpaperSourceIds {
  const WallpaperSourceIds._();

  static const String official = 'official';
  static const String wallhaven = 'wallhaven';
  static const String bing = 'bing';
  static const String deepin = 'deepin';
  static const String video = 'video';
  static const String solidColor = 'solid-color';
}

/// 图源显示名称映射
const Map<String, String> kWallpaperSourceNames = <String, String>{
  WallpaperSourceIds.official: '官方壁纸',
  WallpaperSourceIds.wallhaven: 'Wallhaven',
  WallpaperSourceIds.bing: '必应每日',
  WallpaperSourceIds.deepin: 'deepin',
  WallpaperSourceIds.video: '动态壁纸',
  WallpaperSourceIds.solidColor: '纯色渐变',
};

/// 分组显示名称映射
const Map<String, String> kWallpaperGroupNames = <String, String>{
  // official
  'nature': '自然风光',
  'acg': '二次元',
  'art': '艺术',
  'architecture': '建筑',
  'life': '生活',
  'geometry': '几何',
  'other': '其他',
  // wallhaven
  'popular': '热门',
  'minimalism': '极简',
  'patterns': '图案',
  'landscape': '风景',
  'cosplay': 'Cosplay',
  'spiderman': '蜘蛛侠',
  'ghibli': '吉卜力',
  'naruto': '火影忍者',
  'sci-fi': '科幻',
  'anime': '动漫',
  'anime-girls': '动漫少女',
  'cyberpunk': '赛博朋克',
  'pixel-art': '像素艺术',
  'artwork': '艺术作品',
  'cityscape': '城市景观',
  'digital-art': '数字艺术',
  'fantasy-art': '奇幻艺术',
  'final-fantasy': '最终幻想',
};

String wallpaperSourceName(String id) => kWallpaperSourceNames[id] ?? id;

String wallpaperGroupName(String sourceId, String groupId) {
  return kWallpaperGroupNames[groupId] ?? groupId;
}

/// 整个图源树
class WallpaperCatalog {
  final List<CatalogWallpaperSource> sources;

  const WallpaperCatalog({required this.sources});

  CatalogWallpaperSource? sourceById(String id) {
    for (final source in sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  List<CatalogWallpaperSource> get imageSources =>
      sources.where((source) => source.kind == WallpaperKind.image).toList(growable: false);

  static CatalogWallpaperSource _single(String id, WallpaperKind kind, int count) => CatalogWallpaperSource(
    id: id,
    kind: kind,
    categorized: false,
    count: count,
    groups: <CatalogWallpaperGroup>[CatalogWallpaperGroup(id: 'all', sourceId: id, count: count, hidden: true)],
  );

  factory WallpaperCatalog.builtIn() {
    CatalogWallpaperSource images(String id, bool categorized, List<(String, int)> groups) => CatalogWallpaperSource(
      id: id,
      kind: WallpaperKind.image,
      categorized: categorized,
      count: groups.fold(0, (sum, group) => sum + group.$2),
      groups: <CatalogWallpaperGroup>[
        for (final (String groupId, int count) in groups)
          CatalogWallpaperGroup(id: groupId, sourceId: id, apiQuery: groupId, count: count, hidden: !categorized),
      ],
    );

    const List<(String, String, int)> wallhavenGroups = <(String, String, int)>[
      ('popular', '', 233),
      ('minimalism', 'id:2278', 240),
      ('patterns', 'id:869', 240),
      ('landscape', 'id:711', 240),
      ('nature', 'id:37', 240),
      ('cosplay', 'id:12757', 240),
      ('spiderman', 'id:2319', 240),
      ('ghibli', 'id:1748', 240),
      ('naruto', 'id:78174', 219),
      ('sci-fi', 'id:14', 240),
      ('anime', 'id:1', 240),
      ('anime-girls', 'id:5', 240),
      ('cyberpunk', 'id:376', 240),
      ('pixel-art', 'id:2321', 240),
      ('artwork', 'id:323', 240),
      ('cityscape', 'id:479', 240),
      ('digital-art', 'id:13', 240),
      ('fantasy-art', 'id:853', 240),
      ('final-fantasy', 'id:997', 240),
    ];

    return WallpaperCatalog(
      sources: <CatalogWallpaperSource>[
        images(WallpaperSourceIds.official, true, const <(String, int)>[
          ('nature', 240),
          ('acg', 240),
          ('art', 155),
          ('architecture', 28),
          ('life', 31),
          ('geometry', 72),
          ('other', 240),
        ]),
        CatalogWallpaperSource(
          id: WallpaperSourceIds.wallhaven,
          kind: WallpaperKind.image,
          categorized: true,
          count: wallhavenGroups.fold(0, (sum, group) => sum + group.$3),
          groups: <CatalogWallpaperGroup>[
            for (final (String groupId, String apiQuery, int count) in wallhavenGroups)
              CatalogWallpaperGroup(
                id: groupId,
                sourceId: WallpaperSourceIds.wallhaven,
                apiQuery: apiQuery,
                count: count,
              ),
          ],
        ),
        _single(WallpaperSourceIds.bing, WallpaperKind.image, 2030),
        _single(WallpaperSourceIds.deepin, WallpaperKind.image, 26),
        _single(WallpaperSourceIds.video, WallpaperKind.video, 125),
        _single(WallpaperSourceIds.solidColor, WallpaperKind.gradient, 151),
      ],
    );
  }
}

/// CDN 缩略图处理参数
const String kThumbProcess = 'x-oss-process=image/resize,limit_0,m_fill,w_400,h_225/quality,q_72/format,webp';

/// 为 URL 附加 CDN 缩略图处理
String cdnThumb(String url) {
  if (url.isEmpty || url.contains('x-oss-process')) return url;
  final separator = url.contains('?') ? '&' : '?';
  return '$url$separator$kThumbProcess';
}

/// deepin 壁纸名称
const Map<int, String> kDeepinNames = <int, String>{
  0: 'Purple Salt Flats Sunset',
  1: 'Antelope Canyon Waves',
  2: 'Autumn Forest Canopy',
  3: 'Sunset Mountain Ridge',
  4: 'Deepin Logo Gradient',
  5: 'Deepin Logo Ribbons',
  6: 'Neon Vortex Glow',
  7: 'Aurora Borealis Night',
  8: 'Sandstone Canyon Passage',
  9: 'Starry Desert Dunes',
  10: 'Desert Dunes at Dawn',
  11: 'White Facade Blue Sky',
  12: 'Blue Betta Fish',
  13: 'Vestrahorn Beach Reflection',
  14: 'Snowy Ridges at Dusk',
  15: 'Emerald Coast Aerial',
  16: 'Peak Above the Clouds',
  17: 'Dune Ripples at Sunset',
  18: 'Crescent Dune Moonlight',
  19: 'Misty Lake at Dawn',
  20: 'Foggy Pine Forest',
  21: 'Frozen Lake Sunrise',
  22: 'Snow Peak at Sunset',
  23: 'Jellyfish in Blue Water',
  24: 'Eagle Over the Falls',
  25: 'Mountain Lake Reflection',
};

const String kItabFilesBase = 'https://files.itab.link';

/// 本地图源条目
class LocalWallpapers {
  const LocalWallpapers._();

  static final List<CatalogWallpaperItem> solidItems = <CatalogWallpaperItem>[
    for (var i = 0; i < kWallpaperSolidPalette.length; i++)
      CatalogWallpaperItem(
        id: 'flat-$i',
        name: kWallpaperSolidPalette[i],
        file: 'solid-color#flat-$i',
        css: 'solid ${kWallpaperSolidPalette[i]}',
        gradient: <WallpaperGradientStop>[
          WallpaperGradientStop(color: kWallpaperSolidPalette[i], pos: 0),
          WallpaperGradientStop(color: kWallpaperSolidPalette[i], pos: 100),
        ],
      ),
    for (var i = 0; i < kWallpaperGradients.length; i++)
      CatalogWallpaperItem(
        id: 'gradient-$i',
        name: kWallpaperGradients[i].name,
        file: 'solid-color#gradient-$i',
        css: kWallpaperGradients[i].stops.map((stop) => '${stop.$1} ${stop.$2.round()}%').join(', '),
        deg: kWallpaperGradients[i].deg,
        gradient: <WallpaperGradientStop>[
          for (final (color, pos) in kWallpaperGradients[i].stops) WallpaperGradientStop(color: color, pos: pos),
        ],
      ),
  ];

  static final List<CatalogWallpaperItem> deepinItems = <CatalogWallpaperItem>[
    for (final entry in kDeepinNames.entries)
      CatalogWallpaperItem(
        id: '${entry.key}',
        name: entry.value,
        file: '$kItabFilesBase/wallpaper/deepin/${entry.key}.jpg',
        thumb: cdnThumb('$kItabFilesBase/wallpaper/deepin/${entry.key}.jpg'),
      ),
  ];

  static List<CatalogWallpaperItem> of(String sourceId) => switch (sourceId) {
    WallpaperSourceIds.solidColor => solidItems,
    WallpaperSourceIds.deepin => deepinItems,
    _ => const <CatalogWallpaperItem>[],
  };
}

/// CSS 角度 → Flutter begin/end alignment
(Alignment, Alignment) alignmentsFor(int deg) {
  final double radians = deg * math.pi / 180;
  final double x = math.sin(radians);
  final double y = -math.cos(radians);
  if (x == 0 && y == 0) return (Alignment.bottomCenter, Alignment.topCenter);
  return (Alignment(-x, -y), Alignment(x, y));
}

/// hex 颜色字符串解析为 Color
Color? colorFromHex(String hex) {
  try {
    final String cleaned = hex.replaceAll('#', '');
    final int value = int.parse(cleaned, radix: 16);
    if (cleaned.length == 6) return Color(0xFF000000 | value);
    if (cleaned.length == 8) return Color(value);
    return null;
  } catch (_) {
    return null;
  }
}
