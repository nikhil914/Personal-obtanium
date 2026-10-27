import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/services/http_service.dart';

const String serverSyncUrlFromBuild = String.fromEnvironment('SERVER_SYNC_URL');

/// Secret built into the APK (from the SERVER_SYNC_APP_KEY build secret) and sent
/// with every list request, so the server only answers this app.
const String serverSyncAppKeyFromBuild = String.fromEnvironment(
  'SERVER_SYNC_APP_KEY',
);

/// Header that carries [serverSyncAppKeyFromBuild]. It is dropped if the server
/// redirects to another host.
const String serverSyncAppKeyHeader = 'X-App-Key';

final RegExp _shortServerSyncRef = RegExp(
  r'^([A-Za-z0-9_-]{1,32})(?:/([A-Za-z0-9]{1,4}))?$',
);

/// Turns what the user typed into the URL to fetch.
///
/// A full http(s) URL is used as is. On a build with a SERVER_SYNC_URL, a short
/// form saves typing on a car screen: `2` means list 2 with the built-in code,
/// and `2/ab12` means list 2 with code ab12. Both keep the built-in host.
/// Returns null when the input is neither.
Uri? resolveServerSyncUrl(
  String input, {
  String base = serverSyncUrlFromBuild,
}) {
  final v = input.trim();
  final uri = Uri.tryParse(v);
  if (uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty) {
    return uri;
  }
  final m = _shortServerSyncRef.firstMatch(v);
  final baseUri = Uri.tryParse(base.trim());
  if (m == null ||
      baseUri == null ||
      !(baseUri.scheme == 'http' || baseUri.scheme == 'https') ||
      baseUri.host.isEmpty) {
    return null;
  }
  final code = m.group(2) ?? baseUri.queryParameters['key'];
  return baseUri.replace(
    path: '/apps/${m.group(1)!.toLowerCase()}',
    queryParameters: code == null || code.isEmpty ? null : {'key': code},
  );
}

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
  String appKey = serverSyncAppKeyFromBuild,
  String base = serverSyncUrlFromBuild,
}) async {
  final uri = resolveServerSyncUrl(url, base: base);
  if (uri == null) {
    throw ObtainiumError('${tr('invalidServerSyncUrl')}: $url');
  }
  final res = await (httpService ?? HttpService())
      .request(
        'GET',
        {
          'Accept': 'application/json, text/plain',
          if (appKey.isNotEmpty) serverSyncAppKeyHeader: appKey,
        },
        {'url': uri.toString()},
      )
      .timeout(timeout);
  ensureHttpSuccess(res);
  return parseServerAppList(utf8.decode(res.bodyBytes, allowMalformed: true));
}
