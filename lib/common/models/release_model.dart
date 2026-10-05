class ReleaseModel {
  final String version;
  final String title;
  final String date;
  final String github;
  final AuthorModel author;
  final String changelog;
  final List<ReleaseFileModel> files;
  final bool isPrerelease;
  final bool isLatest;

  ReleaseModel({
    required this.version,
    required this.title,
    required this.date,
    required this.github,
    required this.author,
    required this.changelog,
    required this.files,
    this.isPrerelease = false,
    this.isLatest = false,
  });

  factory ReleaseModel.fromJson(Map<String, dynamic> json) {
    final version = json['version'] ?? json['tagName'] ?? '';

    final filesData = json['files'] ?? json['assets'] ?? [];

    final authorData = json['author'] ?? {};
    final authorName = authorData['name'] ?? authorData['login'] ?? '';

    final date = json['date'] ?? json['publishedAt'] ?? '';

    return ReleaseModel(
      version: version,
      title: json['title'] ?? json['name'] ?? '',
      date: date,
      github: json['github'] ?? json['url'] ?? '',
      author: AuthorModel(
        name: authorName,
        avatar: authorData['avatar'] ?? '',
        profile: authorData['profile'] ?? authorData['html_url'] ?? '',
      ),
      changelog: json['changelog'] ?? json['body'] ?? '',
      // 同时兼容 fork feed（isPrerelease/isLatest）与旧脚本 feed（prerelease/latest），
      // 字段缺失的旧 feed 默认 false，不影响历史版本展示。
      isPrerelease: json['isPrerelease'] == true || json['prerelease'] == true,
      isLatest: json['isLatest'] == true || json['latest'] == true,
      files: filesData.map<ReleaseFileModel>((e) {
        final rawSize = e['size'];
        final sizeText = switch (rawSize) {
          String text => text,
          num n => _formatByteSize(n.toInt()),
          _ => '0 B',
        };
        return ReleaseFileModel(
          name: e['name'] ?? '',
          size: sizeText,
          downloads: (e['downloads'] ?? e['downloadCount'] ?? 0) as int,
          url: e['url'] ?? '',
        );
      }).toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'title': title,
      'date': date,
      'github': github,
      'author': author.toJson(),
      'changelog': changelog,
      'isPrerelease': isPrerelease,
      'isLatest': isLatest,
      'files': files.map((e) => e.toJson()).toList(),
    };
  }

  static String _formatByteSize(int bytes) {
    if (bytes < 0) bytes = 0;
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    double size = bytes / 1024;
    int unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    return '${size.toStringAsFixed(2)} ${units[unitIndex]}';
  }
}

class AuthorModel {
  final String name;
  final String avatar;
  final String profile;

  AuthorModel({required this.name, required this.avatar, required this.profile});

  factory AuthorModel.fromJson(Map<String, dynamic> json) {
    return AuthorModel(name: json['name'] ?? '', avatar: json['avatar'] ?? '', profile: json['profile'] ?? '');
  }

  Map<String, dynamic> toJson() {
    return {'name': name, 'avatar': avatar, 'profile': profile};
  }
}

class ReleaseFileModel {
  final String name;
  final String size;
  final int downloads;
  final String url;

  ReleaseFileModel({required this.name, required this.size, required this.downloads, required this.url});

  factory ReleaseFileModel.fromJson(Map<String, dynamic> json) {
    return ReleaseFileModel(
      name: json['name'] ?? '',
      size: json['size'] ?? '',
      downloads: json['downloads'] ?? 0,
      url: json['url'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {'name': name, 'size': size, 'downloads': downloads, 'url': url};
  }
}
