import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';

import 'package_files.dart';
import 'workspace.dart';

const _contentType = 'application/vnd.pub.v2+json';
const _defaultMode = 420;
const _executableMask = 73;

/// A pub hosted repository that serves the packages of a [Workspace] from
/// their directories and forwards every other request to [upstream].
///
/// Pass [url] to pana as the hosted URL, so that a package depending on an
/// unpublished version of a sibling package resolves it from the checkout.
class PackageServer {
  PackageServer._(this._server, this._client, this.workspace, this.upstream);

  /// Starts a server on a free loopback port.
  ///
  /// [upstream] defaults to `PUB_HOSTED_URL`, or pub.dev when it is not set.
  static Future<PackageServer> start(
    Workspace workspace, {
    Uri? upstream,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final packageServer = PackageServer._(
      server,
      HttpClient(),
      workspace,
      upstream ?? defaultUpstream(),
    );
    server.listen(packageServer._handle);
    return packageServer;
  }

  /// The hosted repository that `dart pub` uses when nothing else is
  /// configured.
  static Uri defaultUpstream() =>
      Uri.parse(Platform.environment['PUB_HOSTED_URL'] ?? 'https://pub.dev');

  final HttpServer _server;
  final HttpClient _client;
  final Map<String, Future<List<int>>> _archives = {};

  /// The workspace whose packages are served from the checkout.
  final Workspace workspace;

  /// The hosted repository that every other request is forwarded to.
  final Uri upstream;

  /// The URL to pass as the hosted URL.
  Uri get url => Uri.parse('http://${_server.address.host}:${_server.port}');

  /// Stops the server.
  Future<void> close() async {
    await _server.close(force: true);
    _client.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      final package = segments.length == 3 && segments[0] == 'api'
          ? workspace.packages[segments[2]]
          : null;
      if (package != null && segments[1] == 'packages') {
        await _serveListing(request, package);
      } else if (package != null && segments[1] == 'archives') {
        request.response
          ..headers.contentType = ContentType.binary
          ..add(await _archive(package));
      } else {
        await _forward(request);
      }
    } on Object catch (error) {
      stderr.writeln('${request.method} ${request.uri} failed: $error');
      try {
        request.response.statusCode = HttpStatus.badGateway;
      } on StateError {
        // The headers were already sent, so closing the response is all that
        // is left to do.
      }
    }
    await request.response.close();
  }

  Future<void> _serveListing(
    HttpRequest request,
    WorkspacePackage package,
  ) async {
    final upstreamRequest = await _client.getUrl(_upstreamUrl(request.uri));
    upstreamRequest.headers.set(HttpHeaders.acceptHeader, _contentType);
    final upstreamResponse = await upstreamRequest.close();
    final body = await utf8.decodeStream(upstreamResponse);
    final Map<String, Object?> listing;
    if (upstreamResponse.statusCode == HttpStatus.ok) {
      listing = jsonDecode(body) as Map<String, Object?>;
    } else if (upstreamResponse.statusCode == HttpStatus.notFound) {
      listing = {'name': package.name};
    } else {
      throw HttpException(
        '${upstreamResponse.statusCode} from upstream: $body',
        uri: request.uri,
      );
    }
    request.response
      ..headers.contentType = ContentType.parse(_contentType)
      ..write(jsonEncode(mergeListing(listing, package, url)));
  }

  Future<List<int>> _archive(WorkspacePackage package) =>
      _archives[package.name] ??= createArchive(package.directory);

  Future<void> _forward(HttpRequest request) async {
    final upstreamRequest = await _client.openUrl(
      request.method,
      _upstreamUrl(request.uri),
    );
    upstreamRequest.headers.set(
      HttpHeaders.acceptHeader,
      request.headers.value(HttpHeaders.acceptHeader) ?? _contentType,
    );
    final upstreamResponse = await upstreamRequest.close();
    request.response.statusCode = upstreamResponse.statusCode;
    final contentType = upstreamResponse.headers.contentType;
    if (contentType != null) {
      request.response.headers.contentType = contentType;
    }
    await request.response.addStream(upstreamResponse);
  }

  Uri _upstreamUrl(Uri requestUri) {
    final base = upstream.path.endsWith('/')
        ? upstream.path.substring(0, upstream.path.length - 1)
        : upstream.path;
    return upstream.replace(
      path: '$base${requestUri.path}',
      query: requestUri.hasQuery ? requestUri.query : null,
    );
  }
}

/// Adds the checkout version of [package] to the upstream version [listing],
/// replacing a published version with the same number.
///
/// The checkout version becomes the latest version when the listing has no
/// latest version or when its latest version is the one being replaced.
Map<String, Object?> mergeListing(
  Map<String, Object?> listing,
  WorkspacePackage package,
  Uri serverUrl,
) {
  final entry = {
    'version': package.version,
    'pubspec': package.pubspec,
    'archive_url': serverUrl
        .replace(path: '/api/archives/${package.name}')
        .toString(),
  };
  final versions = [
    for (final version in listing['versions'] as List<Object?>? ?? const [])
      if ((version! as Map<String, Object?>)['version'] != package.version)
        version,
    entry,
  ];
  final latest = listing['latest'] as Map<String, Object?>?;
  return {
    ...listing,
    'name': package.name,
    'versions': versions,
    'latest': latest == null || latest['version'] == package.version
        ? entry
        : latest,
  };
}

/// Creates the `.tar.gz` archive that `dart pub publish` would upload for the
/// package in [packageDirectory].
Future<List<int>> createArchive(String packageDirectory) async {
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  final entries = Stream.fromIterable(
    listPackageFiles(packageDirectory).map((path) {
      final file = File(p.joinAll([packageDirectory, ...p.posix.split(path)]));
      final stat = file.statSync();
      return TarEntry(
        TarHeader(
          name: path,
          mode: _defaultMode | (stat.mode & _executableMask),
          size: stat.size,
          modified: epoch,
          userName: 'pub',
          groupName: 'pub',
        ),
        file.openRead(),
      );
    }),
  );
  final bytes = <int>[];
  await entries
      .transform(tarWriterWith(format: OutputFormat.gnuLongName))
      .transform(gzip.encoder)
      .forEach(bytes.addAll);
  return bytes;
}
