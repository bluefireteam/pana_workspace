import 'dart:convert';
import 'dart:io';

import 'package:pana_workspace/pana_workspace.dart';
import 'package:tar/tar.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('mergeListing', () {
    final package = WorkspacePackage(
      directory: '/workspace/packages/a',
      pubspec: {'name': 'a', 'version': '2.0.0'},
    );
    final serverUrl = Uri.parse('http://127.0.0.1:1234');

    Map<String, Object?> version(String number) => {
      'version': number,
      'pubspec': {'name': 'a', 'version': number},
      'archive_url': 'https://pub.dev/api/archives/a-$number.tar.gz',
    };

    test('adds the checkout version and keeps a newer latest version', () {
      final merged = mergeListing(
        {
          'name': 'a',
          'latest': version('3.0.0'),
          'versions': [version('1.0.0'), version('3.0.0')],
        },
        package,
        serverUrl,
      );

      final versions = merged['versions']! as List<Object?>;
      expect(
        versions.map((entry) => (entry! as Map<String, Object?>)['version']),
        ['1.0.0', '3.0.0', '2.0.0'],
      );
      expect((merged['latest']! as Map<String, Object?>)['version'], '3.0.0');
      expect(
        (versions.last! as Map<String, Object?>)['archive_url'],
        'http://127.0.0.1:1234/api/archives/a',
      );
    });

    test('replaces a published version with the same number', () {
      final merged = mergeListing(
        {
          'name': 'a',
          'latest': version('2.0.0'),
          'versions': [version('1.0.0'), version('2.0.0')],
        },
        package,
        serverUrl,
      );

      final latest = merged['latest']! as Map<String, Object?>;
      expect(latest['archive_url'], 'http://127.0.0.1:1234/api/archives/a');
      expect(merged['versions'], hasLength(2));
    });

    test('creates a listing for a package that was never published', () {
      final merged = mergeListing({'name': 'a'}, package, serverUrl);

      expect((merged['latest']! as Map<String, Object?>)['version'], '2.0.0');
      expect(merged['versions'], hasLength(1));
    });
  });

  group('PackageServer', () {
    late HttpServer upstream;
    late List<String> upstreamRequests;
    late PackageServer server;
    late HttpClient client;

    setUp(() async {
      upstreamRequests = [];
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        upstreamRequests.add(request.uri.path);
        if (request.uri.path == '/api/packages/a') {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.write('{"name":"upstream"}');
        }
        await request.response.close();
      });
      final root = createTree({
        'pubspec.yaml': 'name: root\nworkspace:\n  - packages/a',
        'packages/a/pubspec.yaml': pubspec('a', version: '0.1.0'),
        'packages/a/lib/a.dart': 'void a() {}',
        'packages/a/pubspec.lock': '',
      });
      server = await PackageServer.start(
        Workspace.load(root),
        upstream: Uri.parse('http://127.0.0.1:${upstream.port}'),
      );
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.close();
      await upstream.close(force: true);
    });

    Future<HttpClientResponse> get(String path) async =>
        (await client.getUrl(server.url.replace(path: path))).close();

    test('serves a workspace package that upstream does not know', () async {
      final response = await get('/api/packages/a');
      final listing =
          jsonDecode(await utf8.decodeStream(response)) as Map<String, Object?>;

      expect(response.statusCode, HttpStatus.ok);
      expect((listing['latest']! as Map<String, Object?>)['version'], '0.1.0');
      expect(upstreamRequests, ['/api/packages/a']);
    });

    test('serves the archive of a workspace package', () async {
      final response = await get('/api/archives/a');
      final names = <String>[];
      final reader = TarReader(response.transform(gzip.decoder));
      while (await reader.moveNext()) {
        names.add(reader.current.name);
      }

      expect(names, ['lib/a.dart', 'pubspec.yaml']);
    });

    test('forwards every other request upstream', () async {
      final response = await get('/api/packages/http');

      expect(await utf8.decodeStream(response), '{"name":"upstream"}');
      expect(upstreamRequests, ['/api/packages/http']);
    });
  });
}
