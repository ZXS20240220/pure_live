import 'package:flutter/painting.dart';

/// 壁纸类型
enum WallpaperType {
  /// 无壁纸（纯色/默认背景）
  none,

  /// 本地静态图片
  imageLocal,

  /// 在线静态图片
  imageOnline,

  /// 预设静态图片
  imagePreset,

  /// 本地视频
  videoLocal,

  /// 在线视频
  videoOnline,
}

extension WallpaperTypeX on WallpaperType {
  /// 是否为视频类型
  bool get isVideo => this == WallpaperType.videoLocal || this == WallpaperType.videoOnline;

  /// 是否为图片类型
  bool get isImage =>
      this == WallpaperType.imageLocal || this == WallpaperType.imageOnline || this == WallpaperType.imagePreset;

  /// 是否为本地来源
  bool get isLocal => this == WallpaperType.imageLocal || this == WallpaperType.videoLocal;

  /// 是否为在线来源
  bool get isOnline => this == WallpaperType.imageOnline || this == WallpaperType.videoOnline;
}

/// 壁纸填充方式索引
class WallpaperFit {
  static const int cover = 0;
  static const int contain = 1;
  static const int fill = 2;
  static const int fitWidth = 3;
  static const int fitHeight = 4;
  static const int none = 5;
  static const int scaleDown = 6;

  static const List<String> labels = [
    'wallpaper_fit_cover',
    'wallpaper_fit_contain',
    'wallpaper_fit_fill',
    'wallpaper_fit_fitWidth',
    'wallpaper_fit_fitHeight',
    'wallpaper_fit_none',
    'wallpaper_fit_scaleDown',
  ];

  static BoxFit toBoxFit(int index) {
    switch (index) {
      case cover:
        return BoxFit.cover;
      case contain:
        return BoxFit.contain;
      case fill:
        return BoxFit.fill;
      case fitWidth:
        return BoxFit.fitWidth;
      case fitHeight:
        return BoxFit.fitHeight;
      case none:
        return BoxFit.none;
      case scaleDown:
        return BoxFit.scaleDown;
      default:
        return BoxFit.cover;
    }
  }
}

/// 壁纸项数据模型
class WallpaperItem {
  final String id;
  final WallpaperType type;
  final String url;
  final String? thumbnail;
  final String? name;
  final Map<String, String>? headers;

  const WallpaperItem({
    required this.id,
    required this.type,
    required this.url,
    this.thumbnail,
    this.name,
    this.headers,
  });

  WallpaperItem copyWith({
    String? id,
    WallpaperType? type,
    String? url,
    String? thumbnail,
    String? name,
    Map<String, String>? headers,
  }) {
    return WallpaperItem(
      id: id ?? this.id,
      type: type ?? this.type,
      url: url ?? this.url,
      thumbnail: thumbnail ?? this.thumbnail,
      name: name ?? this.name,
      headers: headers ?? this.headers,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'url': url,
    if (thumbnail != null) 'thumbnail': thumbnail,
    if (name != null) 'name': name,
    if (headers != null) 'headers': headers,
  };

  factory WallpaperItem.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String? ?? 'none';
    final type = WallpaperType.values.firstWhere((e) => e.name == typeName, orElse: () => WallpaperType.none);
    return WallpaperItem(
      id: json['id'] as String? ?? '',
      type: type,
      url: json['url'] as String? ?? '',
      thumbnail: json['thumbnail'] as String?,
      name: json['name'] as String?,
      headers: (json['headers'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())),
    );
  }
}
