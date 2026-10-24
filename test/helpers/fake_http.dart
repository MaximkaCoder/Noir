import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A recorded request with its decoded body.
class FakeRequest {
  FakeRequest(this.options, this.body);

  final RequestOptions options;
  final String body;

  Uri get uri => options.uri;
  String get method => options.method;
  String? get authorization => options.headers['Authorization'] as String?;

  Map<String, String> get form => Uri.splitQueryString(body);
}

/// Response the handler returns: status + JSON body.
typedef FakeReply = ({int status, Object? json});

/// Dio adapter that answers from a handler instead of the network.
class FakeHttp implements HttpClientAdapter {
  FakeHttp(this.handler);

  FakeReply Function(FakeRequest request) handler;
  final requests = <FakeRequest>[];

  Dio dio() => Dio()..httpClientAdapter = this;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    final request = FakeRequest(options, utf8.decode(bytes));
    requests.add(request);
    final reply = handler(request);
    return ResponseBody.fromString(
      jsonEncode(reply.json),
      reply.status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

FakeReply ok(Object? json) => (status: 200, json: json);

FakeReply error(int status, Object? json) => (status: status, json: json);

/// A JWT whose payload carries [claims]; the signature is irrelevant here.
String fakeIdToken(Map<String, Object?> claims) {
  String part(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part(claims)}.sig';
}
