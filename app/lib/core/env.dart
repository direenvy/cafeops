/// Build-time configuration.
///
/// Values come from `--dart-define`, with defaults that point at the project's
/// own Supabase instance so the app runs straight after a clone:
///
/// ```sh
/// flutter run -d chrome \
///   --dart-define=API_BASE_URL=http://localhost:5081
/// ```
///
/// On the publishable key being committed: that is what it is for. A Supabase
/// publishable (anon) key identifies the project, it does not authorise
/// anything. Every row it can reach is decided by the row-level security
/// policies in `supabase/migrations`, which is why those policies are the real
/// security boundary and are worth reading before trusting this app. The keys
/// that *do* carry authority — the service role key and the Postgres password —
/// are held only by the API and never appear in this repository.
library;

class Env {
  const Env._();

  /// Supabase project URL.
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://uwpdphwojqdevqepzglj.supabase.co',
  );

  /// Publishable key. Safe to ship in a client; see the note above.
  static const String supabasePublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_nj9_2T9MX7jydu6G6XbG_A_XXzqmPSn',
  );

  /// Base URL of the ASP.NET Core API that owns the write path.
  ///
  /// Defaults to the local development server. Point it at the deployed API
  /// for a release build.
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:5081',
  );

  /// Currency symbol used across the UI.
  static const String currencySymbol = 'RM';

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;
}
