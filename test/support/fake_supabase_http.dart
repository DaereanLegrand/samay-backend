// ignore_for_file: depend_on_referenced_packages
//
// package:http is a transitive dependency pinned by supabase_flutter; test
// seams are the only code that imports it directly (I-45, 2026-08-09).

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// In-memory Supabase harness with a deterministic HTTP layer (I-45).
///
/// The screens under test in `test/features/` call `SupabaseService.instance`
/// directly (a singleton backed by `Supabase.instance.client`), so the only
/// hermetic seam is the HTTP client injected at `Supabase.initialize`:
/// [RecordingHttpClient] answers every PostgREST request with `200 []` — no
/// network ever leaves the test — while recording method + URL so tests can
/// assert the exact service calls (e.g. `DELETE /rest/v1/group_members?`
/// `group_id=eq.` + the group id after confirming the leave-group dialog).
///
/// An optional persisted session ([initSupabaseHarness]'s `sessionEmail`)
/// makes `Supabase.instance.client.auth.currentUser` resolve, which the
/// delete-account and leave-group flows require. The fake access token is not
/// a real JWT, so `Session.expiresAt` is null → gotrue treats the session as
/// not expired and never attempts a token refresh (no auth HTTP).
class RecordingHttpClient extends http.BaseClient {
  final List<http.BaseRequest> requests = [];

  /// When set, [send] throws it instead of answering — lets tests exercise
  /// service-failure paths hermetically.
  Object? error;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (error != null) throw error!;
    return http.StreamedResponse(
      Stream.value(utf8.encode('[]')),
      200,
      // `http.Response.fromStream` propagates `response.request`; postgrest
      // dereferences it (`response.request!.headers`), so it must survive.
      request: request,
      headers: const {'content-type': 'application/json'},
    );
  }

  /// Whether a request with [method] and a query containing [queryFragment]
  /// was recorded, e.g. `sent('DELETE', 'group_id=eq.<id>')`.
  bool sent(String method, String queryFragment) => requests.any(
        (r) =>
            r.method == method &&
            r.url.queryParameters.entries.any(
              (e) => '${e.key}=${e.value}' == queryFragment,
            ),
      );

  /// Whether a POST to the `rpc/[fn]` endpoint was recorded whose JSON body
  /// contains [bodyFragment] (postgrest sends RPC params in the body, not the
  /// query), e.g. `sentRpc('accept_friend_request', '"p_friendship_id":"f1"')`.
  bool sentRpc(String fn, [String? bodyFragment]) => requests.any(
        (r) =>
            r.method == 'POST' &&
            r.url.path.endsWith('/rpc/$fn') &&
            (bodyFragment == null ||
                (r is http.Request && r.body.contains(bodyFragment))),
      );
}

/// In-memory `LocalStorage` pair (proven in `test/router/app_router_test.dart`
/// and `integration_test/support/fake_supabase.dart`). [SeededMemoryLocalStorage]
/// pre-persists a session so the client starts authenticated.
class MemoryLocalStorage extends LocalStorage {
  MemoryLocalStorage([this._token]);

  String? _token;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() async => _token != null;

  @override
  Future<String?> accessToken() async => _token;

  @override
  Future<void> persistSession(String persistSessionString) async {
    _token = persistSessionString;
  }

  @override
  Future<void> removePersistedSession() async {
    _token = null;
  }
}

/// In-memory substitute for `SharedPreferencesGotrueAsyncStorage` (PKCE
/// verifier + auth code storage).
class MemoryAsyncStorage extends GotrueAsyncStorage {
  final Map<String, String> _items = {};

  @override
  Future<String?> getItem({required String key}) async => _items[key];

  @override
  Future<void> setItem({required String key, required String value}) async {
    _items[key] = value;
  }

  @override
  Future<void> removeItem({required String key}) async {
    _items.remove(key);
  }
}

/// Default identity for the seeded session.
const kHarnessUserId = '11111111-1111-1111-1111-111111111111';

/// Serialized gotrue session JSON for [email]. The access token is not a real
/// JWT → `expiresAt` is null → the session is never "expired" and no refresh
/// HTTP is attempted during initialization.
String seededSessionJson(String email, {String userId = kHarnessUserId}) =>
    jsonEncode({
      'access_token': 'test-access-token',
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'test-refresh-token',
      'user': {
        'id': userId,
        'email': email,
        'aud': 'authenticated',
        'role': 'authenticated',
        'app_metadata': <String, dynamic>{},
        'user_metadata': <String, dynamic>{},
      },
    });

/// Result of [initSupabaseHarness]: the shared recording client (for request
/// assertions) plus a handle to the client the app code sees.
class SupabaseHarness {
  SupabaseHarness(this.http);

  final RecordingHttpClient http;
}

SupabaseHarness? _initialized;

/// The recording client of the initialized harness (null before
/// [initSupabaseHarness] ran) — for request assertions in widget tests.
RecordingHttpClient get harnessHttp => _initialized!.http;

/// Idempotent `Supabase.initialize` with in-memory storages and the
/// deterministic HTTP layer. Safe to call once per test process (Flutter runs
/// each test file in its own isolate); the URL is never contacted.
///
/// Pass [sessionEmail] to start authenticated (persisted session).
Future<SupabaseHarness> initSupabaseHarness({String? sessionEmail}) async {
  final existing = _initialized;
  if (existing != null) return existing;

  final http = RecordingHttpClient();
  await Supabase.initialize(
    url: 'http://127.0.0.1:54386',
    anonKey: 'test-anon-key',
    httpClient: http,
    // No auto-refresh ticks in the harness: the periodic timer gotrue would
    // otherwise schedule in the test process' outer zone is pure noise.
    authOptions: FlutterAuthClientOptions(
      localStorage: MemoryLocalStorage(
        sessionEmail == null ? null : seededSessionJson(sessionEmail),
      ),
      pkceAsyncStorage: MemoryAsyncStorage(),
      detectSessionInUri: false,
      autoRefreshToken: false,
    ),
    debug: false,
  );
  final harness = SupabaseHarness(http);
  _initialized = harness;
  return harness;
}
