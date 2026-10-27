import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider_server_sync.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/server_sync_service.dart';

App _app(String id, String url) => App(
  id: id,
  url: url,
  author: 'Author',
  name: 'App $id',
  installedVersion: null,
  latestVersion: '1.0.0',
  preferredApkIndex: 0,
  additionalSettings: const {},
);

void main() {
  group('parseServerAppList', () {
    test('reads a JSON array of links', () {
      expect(
        parseServerAppList(
          '["https://github.com/a/one", " https://github.com/b/two "]',
        ),
        const [
          ServerAppEntry('https://github.com/a/one'),
          ServerAppEntry('https://github.com/b/two'),
        ],
      );
    });

    test('reads an object with an apps array and per-app settings', () {
      expect(
        parseServerAppList('''
          {"apps": [
            "https://github.com/a/one",
            {"url": "https://github.com/b/two", "settings": {"apkFilterRegEx": "arm64"}},
            {"name": "no url"}
          ]}
        '''),
        const [
          ServerAppEntry('https://github.com/a/one'),
          ServerAppEntry('https://github.com/b/two', {
            'apkFilterRegEx': 'arm64',
          }),
        ],
      );
    });

    test('accepts repos and urls as the array key', () {
      expect(parseServerAppList('{"repos": ["https://x.dev/r"]}'), const [
        ServerAppEntry('https://x.dev/r'),
      ]);
      expect(parseServerAppList('{"urls": ["https://x.dev/u"]}'), const [
        ServerAppEntry('https://x.dev/u'),
      ]);
    });

    test('reads plain text, skipping blanks, comments and duplicates', () {
      expect(
        parseServerAppList(
          '# car apps\r\nhttps://github.com/a/one\n\nhttps://github.com/a/one\n  https://github.com/b/two  \n',
        ),
        const [
          ServerAppEntry('https://github.com/a/one'),
          ServerAppEntry('https://github.com/b/two'),
        ],
      );
    });

    test('returns nothing for an empty body', () {
      expect(parseServerAppList('  \n '), isEmpty);
      expect(parseServerAppList('[]'), isEmpty);
    });

    test('rejects malformed JSON and unexpected shapes', () {
      expect(() => parseServerAppList('[1, 2'), throwsA(isA<ObtainiumError>()));
      expect(
        () => parseServerAppList('{"apps": "nope"}'),
        throwsA(isA<ObtainiumError>()),
      );
    });
  });

  group('fetchServerAppList', () {
    test('GETs the URL and parses the body', () async {
      late http.Request seen;
      final service = HttpService(
        clientFactory: (_) async => MockClient((request) async {
          seen = request;
          return http.Response('["https://github.com/a/one"]', 200);
        }),
      );
      final entries = await fetchServerAppList(
        'http://1.2.3.4:8080/apps',
        httpService: service,
      );
      expect(seen.method, 'GET');
      expect(seen.url, Uri.parse('http://1.2.3.4:8080/apps'));
      expect(entries, const [ServerAppEntry('https://github.com/a/one')]);
    });

    test('throws on a non-200 response', () async {
      final service = HttpService(
        clientFactory: (_) async =>
            MockClient((_) async => http.Response('nope', 500)),
      );
      expect(
        fetchServerAppList('https://example.com/apps', httpService: service),
        throwsA(isA<ObtainiumError>()),
      );
    });

    test('rejects a URL without scheme or host', () {
      expect(
        fetchServerAppList('example.com/apps'),
        throwsA(isA<ObtainiumError>()),
      );
    });
  });

  group('findAppIdForServerUrl', () {
    final apps = [
      _app('com.a.one', 'https://github.com/a/one'),
      _app('com.b.two', 'https://github.com/b/two'),
    ];

    test('matches the standardized URL', () {
      expect(
        findAppIdForServerUrl(
          apps,
          'https://github.com/a/one/releases',
          'https://github.com/a/one',
        ),
        'com.a.one',
      );
    });

    test('ignores case and trailing slashes', () {
      expect(
        findAppIdForServerUrl(apps, 'https://GitHub.com/B/two/', null),
        'com.b.two',
      );
    });

    test('returns null for an unknown app', () {
      expect(
        findAppIdForServerUrl(apps, 'https://github.com/c/three', null),
        isNull,
      );
    });
  });
}
