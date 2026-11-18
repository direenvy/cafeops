import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'env.dart';

/// A refusal from the API, carrying the stable code from its problem details.
///
/// The UI branches on [code] rather than on message text, so wording can change
/// server-side without breaking the client.
class ApiException implements Exception {
  ApiException({required this.statusCode, required this.message, this.code});

  final int statusCode;
  final String message;
  final String? code;

  bool get isConflict => statusCode == 409;
  bool get isUnauthorized => statusCode == 401 || statusCode == 403;

  @override
  String toString() => message;
}

/// Raised when the API cannot be reached at all.
class ApiUnreachable implements Exception {
  ApiUnreachable(this.baseUrl, this.cause);

  final String baseUrl;
  final Object cause;

  @override
  String toString() => 'Could not reach the API at $baseUrl. Is it running?';
}

/// Talks to the ASP.NET Core API.
///
/// Only the write path goes through here: placing, paying for and cancelling
/// orders, moving stock, and reading reports. Everything else the app reads
/// comes straight from Supabase under row-level security, which is what lets
/// the order board update in realtime.
///
/// The access token is read from the Supabase session on every call rather than
/// captured once, because the SDK refreshes it in the background and a cached
/// copy would start returning 401s after an hour.
class ApiClient {
  ApiClient(this._supabase, {http.Client? httpClient, String? baseUrl})
    : _http = httpClient ?? http.Client(),
      _baseUrl = (baseUrl ?? Env.apiBaseUrl).replaceAll(RegExp(r'/+$'), '');

  final SupabaseClient _supabase;
  final http.Client _http;
  final String _baseUrl;

  /// Generous on purpose.
  ///
  /// A free-tier container is suspended after a few minutes idle, and the
  /// first request afterwards pays the whole cold start — often 30 to 60
  /// seconds. A tighter timeout turns that into "cannot reach the API" on the
  /// very first thing a visitor tries, which is the worst possible moment to
  /// look broken. Once warm, these calls finish in well under a second.
  static const Duration _timeout = Duration(seconds: 90);

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
  }) async {
    final body = await _send('GET', path, query: query);
    return body as Map<String, dynamic>;
  }

  Future<List<dynamic>> getList(
    String path, {
    Map<String, String>? query,
  }) async {
    final body = await _send('GET', path, query: query);
    return body as List<dynamic>;
  }

  Future<Map<String, dynamic>> postJson(String path, {Object? body}) async {
    final result = await _send('POST', path, body: body);
    return result as Map<String, dynamic>;
  }

  Future<List<dynamic>> postList(String path, {Object? body}) async {
    final result = await _send('POST', path, body: body);
    return result as List<dynamic>;
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    final token = _supabase.auth.currentSession?.accessToken;

    if (token == null) {
      throw ApiException(
        statusCode: 401,
        message: 'You are signed out. Sign in again to continue.',
        code: 'auth.no_session',
      );
    }

    final uri = Uri.parse('$_baseUrl$path')
        .replace(queryParameters: query?.isEmpty ?? true ? null : query);

    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
    };

    http.Response response;

    try {
      final request = switch (method) {
        'GET' => _http.get(uri, headers: headers),
        'POST' => _http.post(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        ),
        _ => throw UnsupportedError('Unsupported method $method'),
      };

      response = await request.timeout(_timeout);
    } on TimeoutException catch (error) {
      throw ApiUnreachable(_baseUrl, error);
    } catch (error) {
      throw ApiUnreachable(_baseUrl, error);
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) {
        return <String, dynamic>{};
      }
      return jsonDecode(utf8.decode(response.bodyBytes));
    }

    throw _asException(response);
  }

  /// Turns an RFC 9457 problem-details response into an [ApiException].
  ApiException _asException(http.Response response) {
    String message = 'Request failed (${response.statusCode}).';
    String? code;

    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));

      if (decoded is Map<String, dynamic>) {
        code = decoded['code'] as String?;

        final detail = decoded['detail'] as String?;
        final title = decoded['title'] as String?;

        // ASP.NET's model-binding failures arrive as a map of field -> errors
        // rather than a detail string, so fall back to flattening those.
        final errors = decoded['errors'];
        final flattened = errors is Map<String, dynamic>
            ? errors.values
                  .whereType<List<dynamic>>()
                  .expand((list) => list)
                  .map((item) => item.toString())
                  .join(' ')
            : null;

        message =
            detail ??
            (flattened != null && flattened.isNotEmpty ? flattened : null) ??
            title ??
            message;
      }
    } catch (_) {
      // A non-JSON error body (a proxy's HTML page, say) is not worth
      // surfacing verbatim; the status-code message above is more useful.
    }

    return ApiException(
      statusCode: response.statusCode,
      message: message,
      code: code,
    );
  }

  void dispose() => _http.close();
}
