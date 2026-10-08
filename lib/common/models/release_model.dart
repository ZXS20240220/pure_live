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
    final version = json['version'] ?? json['tagName'];
    final title = json['title'] ?? json['name'];

    final filesData = json['files'] ?? json['assets'] ?? [];

    final authorData = json['author'];
    final authorMap = authorData is Map ? authorData : const <String, dynamic>{};
    final authorName = authorMap['name'] ?? authorMap['login'];

    final date = json['date'] ?? json['publishedAt'] ?? '';

    return ReleaseModel(
      version: version?.toString() ?? '',
      title: title?.toString() ?? '',
      date: date?.toString() ?? '',
      github: (json['github'] ?? json['url'] ?? '').toString(),
      author: AuthorModel(
        name: authorName?.toString() ?? '',
        avatar: (authorMap['avatar'] ?? '').toString(),
        profile: (authorMap['profile'] ?? authorMap['html_url'] ?? '').toString(),
      ),
      changelog: (json['changelog'] ?? json['body'] ?? '').toString(),
      isPrerelease: json['isPrerelease'] == true || json['prerelease'] == true,
      isLatest: json['isLatest'] == true || json['latest'] == true,
      files: filesData is List
          ? filesData.whereType<Map>().map<ReleaseFileModel>((e) {
              final rawSize = e['size'];
              final sizeText = switch (rawSize) {
                String text => text,
                num n => _formatByteSize(n.toInt()),
                _ => '0 B',
              };
              final rawDownloads = e['downloads'] ?? e['downloadCount'];
              final downloads = switch (rawDownloads) {
                int i => i,
                num n => n.toInt(),
                String s => int.tryParse(s) ?? 0,
                _ => 0,
              };
              return ReleaseFileModel(
                name: (e['name'] ?? '').toString(),
                size: sizeText,
                downloads: downloads,
                url: (e['url'] ?? '').toString(),
              );
            }).toList()
          : const [],
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
