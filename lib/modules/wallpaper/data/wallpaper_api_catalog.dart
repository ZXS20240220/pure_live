/// 随机图源 API 的分组与数据源定义。
///
/// 每组包含若干个随机图片 API 源，点击源后会获取一张随机图片并预览。
/// 不同 API 返回格式不同，通过 [WallpaperApiKind] 区分处理方式。
///
/// 端点看起来相似但行为完全不同，因此每个条目都明确指定 kind：
/// * `https://v2.xxapi.cn/api/wallpaper` 返回 JSON 信封 `{"code":200,"data":"..."}`，
///   不是图片。
/// * `https://jkapi.com/api/<name>` 默认返回 HTML 页面，需请求 JSON 后从
///   `image_url` 或 `content` 字段取图。
/// * `https://t.alcy.cc/` 根路径返回 HTML，只有分类路径才返回图片。
/// * 其余（picsum、dmoe、loliapi、mtyqx 等）直接重定向到图片。
library;

/// 随机图片 API 的响应类型
enum WallpaperApiKind {
  /// URL 直接返回图片（跟随重定向）
  direct,

  /// URL 返回 JSON，需要从中解析图片地址
  json,

  /// t.alcy.cc 风格：分类作为 URL 路径段
  alcy,
}

/// 一个随机图源 API 源
class WallpaperApiSource {
  const WallpaperApiSource({
    required this.id,
    required this.name,
    required this.url,
    this.kind = WallpaperApiKind.direct,
    this.apiKey,
  });

  /// 稳定标识，用于生成本地化 key
  final String id;

  /// 显示名称
  final String name;

  /// API 地址
  final String url;

  /// 响应类型
  final WallpaperApiKind kind;

  /// 部分 JSON 端点需要附加 apiKey
  final String? apiKey;

  String get host => Uri.tryParse(url)?.host ?? url;

  /// alcy 主机支持的分类路径段
  ///
  /// 只保留仍可解析的分类：旧版应用发布过 `ai` 和 `aimp`，但主机对两者
  /// 都返回 404，已废弃的条目只会浪费请求。
  static const List<String> alcyCategories = <String>[
    'ycy',
    'moez',
    'ysz',
    'ys',
    'mp',
    'moemp',
    'ysmp',
    'tx',
    'lai',
    'xhl',
    'bd',
  ];

  static const String alcyBase = 'https://t.alcy.cc/';
}

/// 随机图源分组
class WallpaperApiGroup {
  const WallpaperApiGroup({required this.id, required this.name, required this.sources});

  final String id;
  final String name;
  final List<WallpaperApiSource> sources;
}

/// 随机图源分组列表（按上游顺序）
final List<WallpaperApiGroup> kWallpaperApiGroups = <WallpaperApiGroup>[
  WallpaperApiGroup(
    id: 'bing',
    name: '必应壁纸',
    sources: <WallpaperApiSource>[
      const WallpaperApiSource(
        id: 'bing_biturl',
        name: '必应随机Biturl',
        url: 'https://bing.biturl.top/?resolution=1920x1080&format=image&index=random',
      ),
      const WallpaperApiSource(
        id: 'bing_jason_zeng',
        name: '必应随机Jason Zeng',
        url: 'https://bingw.jasonzeng.dev/?resolution=1920x1080&index=random',
      ),
      const WallpaperApiSource(
        id: 'bing_uapi',
        name: '必应随机UAPI',
        url: 'https://uapis.cn/api/v1/image/bing-daily?random=true&resolution=1080',
      ),
      const WallpaperApiSource(id: 'bing_ying_joy', name: '必应随机YingJoy', url: 'https://api.1314.cool/bingimg'),
      const WallpaperApiSource(id: 'bing_w3h5', name: '必应W3H5', url: 'https://bz.w3h5.com/img/rand_fhd'),
      const WallpaperApiSource(
        id: 'bing_wuming_daily',
        name: '无铭必应每日壁纸',
        url: 'https://jkapi.com/api/bing_img',
        kind: WallpaperApiKind.json,
        apiKey: '0f57c17bca42966996d6a8bc28594858',
      ),
    ],
  ),
  WallpaperApiGroup(
    id: 'alcy',
    name: '栗次元',
    sources: <WallpaperApiSource>[
      const WallpaperApiSource(
        id: 'alcy_random',
        name: '栗次元 · 随机',
        url: WallpaperApiSource.alcyBase,
        kind: WallpaperApiKind.alcy,
      ),
      for (final String category in WallpaperApiSource.alcyCategories)
        WallpaperApiSource(
          id: 'alcy_$category',
          name: '栗次元 · $category',
          url: '${WallpaperApiSource.alcyBase}$category',
        ),
    ],
  ),
  WallpaperApiGroup(
    id: 'wuming',
    name: '无铭 API',
    sources: <WallpaperApiSource>[
      const WallpaperApiSource(
        id: 'wuming_girl',
        name: '无铭随机美囡图片',
        url: 'https://jkapi.com/api/meinv_img',
        kind: WallpaperApiKind.json,
        apiKey: '872080c8858c40e6a1eb2ba86694d4d8',
      ),
      const WallpaperApiSource(
        id: 'wuming_black_stocking',
        name: '无铭随机黑丝图片',
        url: 'https://jkapi.com/api/heisi_img',
        kind: WallpaperApiKind.json,
        apiKey: '0c0c7a39e084db0e9c7cf2e25318f42c',
      ),
      const WallpaperApiSource(
        id: 'wuming_douyin_girl',
        name: '抖音美女·无铭API',
        url: 'https://jkapi.com/api/dymm_img',
        kind: WallpaperApiKind.json,
        apiKey: '7b6c5500e52878bc46264cd140196699',
      ),
      const WallpaperApiSource(
        id: 'wuming_white_stocking',
        name: '无铭随机白丝图片',
        url: 'https://jkapi.com/api/baisi_img',
        kind: WallpaperApiKind.json,
        apiKey: '7605369407c689e9b2804bfc56a82ac7',
      ),
      const WallpaperApiSource(
        id: 'wuming_douyin_girl_alt',
        name: '无铭随机抖音美女图片',
        url: 'https://jkapi.com/api/dymm_img',
        kind: WallpaperApiKind.json,
        apiKey: '7b6c5500e52878bc46264cd140196699',
      ),
      const WallpaperApiSource(
        id: 'wuming_bcy_cos',
        name: '无铭半次元cosplay',
        url: 'https://jkapi.com/api/bcy_cos',
        kind: WallpaperApiKind.json,
        apiKey: 'f5bce3b84b7409fbe8abb2246b46f4c8',
      ),
      const WallpaperApiSource(
        id: 'wuming_anime_wallpaper',
        name: '无铭动漫壁纸',
        url: 'https://jkapi.com/api/dm_wallpaper',
        kind: WallpaperApiKind.json,
        apiKey: '95e3a0e608a8b1bed6d513346f929202',
      ),
      const WallpaperApiSource(
        id: 'wuming_aesthetic_girl',
        name: '无铭随机唯美女生图片',
        url: 'https://jkapi.com/api/wm_girl',
        kind: WallpaperApiKind.json,
        apiKey: '0a7c2239bc57624cac60967937da8a1b',
      ),
    ],
  ),
  WallpaperApiGroup(
    id: 'uapi',
    name: 'UAPI 随机图',
    sources: <WallpaperApiSource>[
      const WallpaperApiSource(id: 'uapi_all', name: 'UAPI全部随机', url: 'https://uapis.cn/api/v1/random/image'),
      const WallpaperApiSource(
        id: 'uapi_acg',
        name: 'UAPI二次元动漫',
        url: 'https://uapis.cn/api/v1/random/image?category=acg',
      ),
      const WallpaperApiSource(
        id: 'uapi_acg_pc',
        name: 'UAPI二次元·电脑',
        url: 'https://uapis.cn/api/v1/random/image?category=acg&type=pc',
      ),
      const WallpaperApiSource(
        id: 'uapi_acg_mobile',
        name: 'UAPI二次元·手机',
        url: 'https://uapis.cn/api/v1/random/image?category=acg&type=mb',
      ),
      const WallpaperApiSource(
        id: 'uapi_landscape',
        name: 'UAPI风景图',
        url: 'https://uapis.cn/api/v1/random/image?category=landscape',
      ),
      const WallpaperApiSource(
        id: 'uapi_anime',
        name: 'UAPI混合动漫',
        url: 'https://uapis.cn/api/v1/random/image?category=anime',
      ),
      const WallpaperApiSource(
        id: 'uapi_pc_wallpaper',
        name: 'UAPI电脑壁纸',
        url: 'https://uapis.cn/api/v1/random/image?category=pc_wallpaper',
      ),
      const WallpaperApiSource(
        id: 'uapi_mobile_wallpaper',
        name: 'UAPI手机壁纸',
        url: 'https://uapis.cn/api/v1/random/image?category=mobile_wallpaper',
      ),
      const WallpaperApiSource(
        id: 'uapi_general_anime',
        name: 'UAPI动漫图',
        url: 'https://uapis.cn/api/v1/random/image?category=general_anime',
      ),
      const WallpaperApiSource(
        id: 'uapi_furry',
        name: 'UAPI福瑞',
        url: 'https://uapis.cn/api/v1/random/image?category=furry',
      ),
      const WallpaperApiSource(
        id: 'uapi_furry_z4k',
        name: 'UAPI福瑞·z4k',
        url: 'https://uapis.cn/api/v1/random/image?category=furry&type=z4k',
      ),
      const WallpaperApiSource(
        id: 'uapi_furry_szs8k',
        name: 'UAPI福瑞·szs8k',
        url: 'https://uapis.cn/api/v1/random/image?category=furry&type=szs8k',
      ),
      const WallpaperApiSource(
        id: 'uapi_furry_s4k',
        name: 'UAPI福瑞·s4k',
        url: 'https://uapis.cn/api/v1/random/image?category=furry&type=s4k',
      ),
      const WallpaperApiSource(
        id: 'uapi_furry_4k',
        name: 'UAPI福瑞·4k',
        url: 'https://uapis.cn/api/v1/random/image?category=furry&type=4k',
      ),
    ],
  ),
  WallpaperApiGroup(
    id: '360',
    name: '360壁纸',
    sources: <WallpaperApiSource>[
      const WallpaperApiSource(
        id: '360_beauty',
        name: '360壁纸美女',
        url: 'https://v1.apizero.cn/api/wallpaper?category=美女&resolution=1920x1080&count=1',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: '360_landscape',
        name: '360壁纸风景',
        url: 'https://v1.apizero.cn/api/wallpaper?category=风景&resolution=1920x1080&count=1',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: '360_game',
        name: '360壁纸游戏',
        url: 'https://v1.apizero.cn/api/wallpaper?category=游戏&resolution=1920x1080&count=1',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: '360_movie',
        name: '360壁纸影视',
        url: 'https://v1.apizero.cn/api/wallpaper?category=影视&resolution=1920x1080&count=1',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: '360_fashion',
        name: '360壁纸时尚',
        url: 'https://v1.apizero.cn/api/wallpaper?category=时尚&resolution=1920x1080&count=1',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: '360_star',
        name: '360壁纸明星',
        url: 'https://v1.apizero.cn/api/wallpaper?category=明星&resolution=1920x1080&count=1',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: '360_car',
        name: '360壁纸汽车',
        url: 'https://v1.apizero.cn/api/wallpaper?category=汽车&resolution=1920x1080&count=1',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: '360_pet',
        name: '360壁纸萌宠',
        url: 'https://v1.apizero.cn/api/wallpaper?category=萌宠&resolution=1920x1080&count=1',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: '360_fresh',
        name: '360壁纸清新',
        url: 'https://v1.apizero.cn/api/wallpaper?category=清新&resolution=1920x1080&count=1',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: '360_sport',
        name: '360壁纸体育',
        url: 'https://v1.apizero.cn/api/wallpaper?category=体育&resolution=1920x1080&count=1',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: '360_child',
        name: '360壁纸萌娃',
        url: 'https://v1.apizero.cn/api/wallpaper?category=萌娃&resolution=1920x1080&count=1',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: '360_military',
        name: '360壁纸军事',
        url: 'https://v1.apizero.cn/api/wallpaper?category=军事&resolution=1920x1080&count=1',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: '360_anime',
        name: '360壁纸动漫',
        url: 'https://v1.apizero.cn/api/wallpaper?category=动漫&resolution=1920x1080&count=1',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: '360_calendar',
        name: '360壁纸日历',
        url: 'https://v1.apizero.cn/api/wallpaper?category=日历&resolution=1920x1080&count=1',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: '360_love',
        name: '360壁纸爱情',
        url: 'https://v1.apizero.cn/api/wallpaper?category=爱情&resolution=1920x1080&count=1',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: '360_motto',
        name: '360壁纸格言',
        url: 'https://v1.apizero.cn/api/wallpaper?category=格言&resolution=1920x1080&count=1',
        kind: WallpaperApiKind.json,
      ),
    ],
  ),
  WallpaperApiGroup(
    id: 'misc',
    name: '其他图源',
    sources: <WallpaperApiSource>[
      const WallpaperApiSource(
        id: 'xxapi',
        name: '小晓API',
        url: 'https://v2.xxapi.cn/api/wallpaper',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(id: 'mtyqx', name: 'mtyqx', url: 'https://api.mtyqx.cn/tapi/random.php'),
      const WallpaperApiSource(id: 'picsum', name: 'picsum', url: 'https://picsum.photos/1920/1080'),
      const WallpaperApiSource(id: 'dmoe', name: 'dmoe', url: 'https://www.dmoe.cc/random.php'),
      const WallpaperApiSource(id: 'loliapi', name: 'loliApi', url: 'https://www.loliapi.com/bg/'),
      const WallpaperApiSource(id: 'catvod', name: 'catvod', url: 'https://pictures.catvod.eu.org/'),
    ],
  ),
  WallpaperApiGroup(
    id: 'sexy',
    name: '性感美女',
    sources: <WallpaperApiSource>[
      const WallpaperApiSource(
        id: 'sexy_black_stocking_xxapi',
        name: '随机黑丝·小小API',
        url: 'https://v2.xxapi.cn/api/heisi',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: 'sexy_white_stocking_xxapi',
        name: '随机白丝·小小API',
        url: 'https://v2.xxapi.cn/api/baisi',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: 'sexy_jk_xxapi',
        name: '随机JK·小小API',
        url: 'https://v2.xxapi.cn/api/jk',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(id: 'sexy_girl_suyan', name: '随机小姐姐·素颜API', url: 'https://api.suyanw.cn/api/ksxjj.php'),
      const WallpaperApiSource(id: 'sexy_beauty_suyan', name: '随机美女·素颜API', url: 'https://api.suyanw.cn/api/meinv.php'),
      const WallpaperApiSource(id: 'sexy_meizi_suyan', name: '随机妹子·素颜API', url: 'https://api.suyanw.cn/api/meizi.php'),
      const WallpaperApiSource(
        id: 'sexy_black_stocking_suyan',
        name: '随机黑丝·素颜API',
        url: 'https://api.suyanw.cn/api/hs.php',
      ),
      const WallpaperApiSource(
        id: 'sexy_meizi_xiaodu',
        name: '随机妹子·小渡API',
        url: 'https://openapi.dwo.cc/api/meinv?type=json',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: 'sexy_stocking_nonebot',
        name: '随机丝袜·Nonebot',
        url: 'https://api.nonebot.top/api/v1/random/wallpaper?type=meizi',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(id: 'sexy_pc_ltywl', name: 'PC美女壁纸·Ltywl', url: 'https://pic.ltywl.top/mn/pc.php'),
      const WallpaperApiSource(id: 'sexy_pe_ltywl', name: 'PE美女壁纸·Ltywl', url: 'https://pic.ltywl.top/mn/pe.php'),
      const WallpaperApiSource(
        id: 'sexy_beauty_apizero',
        name: '美女壁纸·极数本源',
        url: 'https://v1.apizero.cn/api/wallpaper?category=美女&resolution=1920x1080&count=1',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: 'sexy_pc_nsuuu',
        name: '电脑端小姐姐·Nsuuu',
        url: 'https://v1.nsuuu.com/api/pcmeinvpic',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: 'sexy_white_stocking_nsuuu',
        name: '随机白丝·Nsuuu',
        url: 'https://v1.nsuuu.com/api/baisi',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: 'sexy_beauty_btstu',
        name: '随机美女·搏天API',
        url: 'http://api.btstu.cn/sjbz/api.php?lx=meizi&format=images',
      ),
      const WallpaperApiSource(
        id: 'sexy_anime_btstu',
        name: '随机二次元·搏天API',
        url: 'http://api.btstu.cn/sjbz/api.php?lx=dongman&format=images',
      ),
      const WallpaperApiSource(
        id: 'sexy_girl_kuaishou',
        name: '随机小姐姐·快手',
        url: 'http://api.nonebot.top/api/v1/random/wallpaper?type=kuaishou',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(
        id: 'sexy_cos_nonebot',
        name: '随机Cos·Nonebot',
        url: 'http://api.nonebot.top/api/v1/random/wallpaper?type=cos',
        kind: WallpaperApiKind.json,
      ),
      const WallpaperApiSource(id: 'sexy_beauty_czl', name: '随机美女·CZL', url: 'https://random-api.czl.net/pic/ai'),
      const WallpaperApiSource(id: 'sexy_beauty_mioical', name: '随机美女·Mioical', url: 'https://api.mioical.moe/img'),
    ],
  ),
];
