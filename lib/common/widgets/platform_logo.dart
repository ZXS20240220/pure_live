import 'package:flutter/material.dart';
import 'package:pure_live/core/sites.dart';

/// Logo size inside a platform tab or chip.
const double kPlatformLogoSize = 18;

/// One platform's logo, rounded and sized for a tab strip or a chip.
///
/// A missing asset falls back to a neutral icon instead of Flutter's red error
/// box: the platform list is compiled in, but artwork can lag behind a newly
/// added site.
class PlatformLogoAsset extends StatelessWidget {
  const PlatformLogoAsset({super.key, required this.asset, this.size = kPlatformLogoSize});

  final String asset;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (asset.isEmpty) return Icon(Icons.live_tv_rounded, size: size);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.asset(
        asset,
        width: size,
        height: size,
        filterQuality: FilterQuality.low,
        errorBuilder: (context, error, stackTrace) => Icon(Icons.live_tv_rounded, size: size),
      ),
    );
  }
}

/// [PlatformLogoAsset] for a resolved platform.
class PlatformLogo extends StatelessWidget {
  const PlatformLogo({super.key, required this.site, this.size = kPlatformLogoSize});

  final Site site;
  final double size;

  @override
  Widget build(BuildContext context) => PlatformLogoAsset(asset: site.logo, size: size);
}

/// A platform tab: the platform's logo followed by its name. Every platform
/// selector builds this one widget.
class PlatformTab extends StatelessWidget {
  const PlatformTab({super.key, required this.site, this.suffix});

  final Site site;
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    final label = suffix == null || suffix!.isEmpty ? site.name : '${site.name} $suffix';
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          PlatformLogo(site: site),
          const SizedBox(width: 6),
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}
