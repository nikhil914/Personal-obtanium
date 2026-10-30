import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/services/http_service.dart';

const String serverSyncUrlFromBuild = String.fromEnvironment('SERVER_SYNC_URL');

const Map<String, dynamic> serverSyncDefaultAppSettings = {
  'autoApkFilterByArch': true,
};

class ServerAppEntry {
  final String url;
  final Map<String, dynamic> settings;

  const ServerAppEntry(this.url, [this.settings = const {}]);

  @override
  bool operator ==(Object other) =>
      other is ServerAppEntry &&
      other.url == url &&
      jsonEncode(other.settings) == jsonEncode(settings);

  @override
  int get hashCode => Object.hash(url, jsonEncode(settings));

  @override
  String toString() => 'ServerAppEntry($url, $settings)';
}

List<ServerAppEntry> parseServerAppList(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return [];
  if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException catch (e) {
      throw ObtainiumError('${tr('serverListInvalid')}: ${e.message}');
    }
    return _entriesFromJson(decoded);
  }
  return _dedupe(
    trimmed
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .map((line) => ServerAppEntry(line)),
  );
}

List<ServerAppEntry> _entriesFromJson(dynamic decoded) {
  dynamic list = decoded;
  if (decoded is Map) {
    list = decoded['apps'] ?? decoded['repos'] ?? decoded['urls'];
  }
  if (list is! List) {
    throw ObtainiumError(tr('serverListInvalid'));
  }
  final entries = <ServerAppEntry>[];
  for (final item in list) {
    if (item is String) {
      if (item.trim().isNotEmpty) entries.add(ServerAppEntry(item.trim()));
    } else if (item is Map) {
      final url = item['url'];
      if (url is! String || url.trim().isEmpty) continue;
      final settings = item['settings'];
      entries.add(
        ServerAppEntry(
          url.trim(),
          settings is Map ? Map<String, dynamic>.from(settings) : const {},
        ),
      );
    }
  }
  return _dedupe(entries);
}

List<ServerAppEntry> _dedupe(Iterable<ServerAppEntry> entries) {
  final seen = <String>{};
  return entries.where((e) => seen.add(e.url)).toList();
}

Future<List<ServerAppEntry>> fetchServerAppList(
  String url, {
  HttpService? httpService,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw ObtainiumError('${tr('invalidServerSyncUrl')}: $url');
  }
  final res = await (httpService ?? HttpService())
      .request(
        'GET',
        {'Accept': 'application/json, text/plain'},
        {'url': uri.toString()},
      )
      .timeout(timeout);
  ensureHttpSuccess(res);
  return parseServerAppList(utf8.decode(res.bodyBytes, allowMalformed: true));
}
