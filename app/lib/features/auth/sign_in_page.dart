import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers.dart';

/// Email and password sign-in, with sign-up on the same screen.
///
/// Supabase owns the credentials: this screen never sees a password hash and
/// the app never stores one. New accounts are created as staff — the role is
/// not taken from anything the client sends, so a sign-up form cannot make
/// itself a manager.
class SignInPage extends ConsumerStatefulWidget {
  const SignInPage({super.key});

  @override
  ConsumerState<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends ConsumerState<SignInPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();

  bool _isSigningUp = false;
  bool _busy = false;
  bool _obscure = true;
  String? _error;
  String? _notice;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });

    final auth = ref.read(supabaseProvider).auth;
    final email = _email.text.trim();
    final password = _password.text;

    try {
      if (_isSigningUp) {
        final response = await auth.signUp(
          email: email,
          password: password,
          data: {'full_name': _name.text.trim()},
        );

        // With email confirmation on (the Supabase default) sign-up returns a
        // user but no session, so say what happens next instead of appearing to
        // do nothing.
        if (response.session == null && mounted) {
          setState(() {
            _isSigningUp = false;
            _notice =
                'Account created. Check $email for the confirmation '
                'link, then sign in.';
          });
        }
      } else {
        await auth.signInWithPassword(email: email, password: password);
      }
    } on AuthException catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Something went wrong. $error');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.coffee_rounded, size: 56, color: scheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    'CafeOps',
                    textAlign: TextAlign.center,
                    style: textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _isSigningUp
                        ? 'Create an account to join the floor'
                        : 'Sign in to the floor',
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),

                  if (_isSigningUp) ...[
                    TextFormField(
                      controller: _name,
                      textInputAction: TextInputAction.next,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Your name',
                        prefixIcon: Icon(Icons.badge_outlined),
                      ),
                      validator: (value) =>
                          (value == null || value.trim().isEmpty)
                          ? 'Enter your name'
                          : null,
                    ),
                    const SizedBox(height: 12),
                  ],

                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.mail_outline),
                    ),
                    validator: (value) {
                      final email = value?.trim() ?? '';
                      if (email.isEmpty) {
                        return 'Enter your email';
                      }
                      if (!email.contains('@') || !email.contains('.')) {
                        return 'That does not look like an email address';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _password,
                    obscureText: _obscure,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _busy ? null : _submit(),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        tooltip: _obscure ? 'Show password' : 'Hide password',
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Enter your password';
                      }
                      // Supabase rejects anything shorter, so catch it here
                      // rather than after a round trip.
                      if (_isSigningUp && value.length < 6) {
                        return 'Use at least 6 characters';
                      }
                      return null;
                    },
                  ),

                  if (_notice != null) ...[
                    const SizedBox(height: 16),
                    _Banner(
                      text: _notice!,
                      icon: Icons.mark_email_read_outlined,
                      background: scheme.secondaryContainer,
                      foreground: scheme.onSecondaryContainer,
                    ),
                  ],

                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    _Banner(
                      text: _error!,
                      icon: Icons.error_outline,
                      background: scheme.errorContainer,
                      foreground: scheme.onErrorContainer,
                    ),
                  ],

                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_isSigningUp ? 'Create account' : 'Sign in'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _isSigningUp = !_isSigningUp;
                            _error = null;
                            _notice = null;
                          }),
                    child: Text(
                      _isSigningUp
                          ? 'I already have an account'
                          : 'Create an account',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'New accounts start as staff. An owner promotes them to '
                    'manager.',
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.text,
    required this.icon,
    required this.background,
    required this.foreground,
  });

  final String text;
  final IconData icon;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: foreground, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
