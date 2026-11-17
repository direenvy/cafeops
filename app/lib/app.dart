import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'core/theme.dart';
import 'features/auth/sign_in_page.dart';
import 'features/shell/home_shell.dart';

class CafeOpsApp extends StatelessWidget {
  const CafeOpsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CafeOps',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const AuthGate(),
    );
  }
}

/// Decides between the sign-in screen and the app.
///
/// Gates on the profile rather than just the session: a signed-in user whose
/// profile is missing or deactivated has an identity but no role, and letting
/// them through would produce a shell with every screen erroring.
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authChangesProvider);
    final supabase = ref.watch(supabaseProvider);

    // currentSession is read directly rather than from the stream, because the
    // stream has not emitted yet on a cold start with a restored session.
    final hasSession = supabase.auth.currentSession != null;

    if (auth.isLoading && !hasSession) {
      return const _Splash();
    }

    if (!hasSession) {
      return const SignInPage();
    }

    final profile = ref.watch(currentProfileProvider);

    return profile.when(
      loading: () => const _Splash(),
      error: (error, _) => _ProfileProblem(
        message: 'Could not load your profile.\n$error',
        onSignOut: () => supabase.auth.signOut(),
        onRetry: () => ref.invalidate(currentProfileProvider),
      ),
      data: (profile) {
        if (profile == null) {
          return _ProfileProblem(
            message:
                'Your account has no profile row yet. Sign out and back in, '
                'or ask an owner to check your account.',
            onSignOut: () => supabase.auth.signOut(),
            onRetry: () => ref.invalidate(currentProfileProvider),
          );
        }

        if (!profile.isActive) {
          return _ProfileProblem(
            message: 'Your account has been deactivated.',
            onSignOut: () => supabase.auth.signOut(),
          );
        }

        return HomeShell(profile: profile);
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _ProfileProblem extends StatelessWidget {
  const _ProfileProblem({
    required this.message,
    required this.onSignOut,
    this.onRetry,
  });

  final String message;
  final VoidCallback onSignOut;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.person_off_outlined,
                  size: 48,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    if (onRetry != null)
                      OutlinedButton(
                        onPressed: onRetry,
                        child: const Text('Try again'),
                      ),
                    FilledButton(
                      onPressed: onSignOut,
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
