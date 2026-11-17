import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/api_client.dart';
import '../core/theme.dart';

/// Renders an [AsyncValue] with consistent loading, error and empty states.
///
/// Worth centralising: a screen that forgets the error branch silently shows an
/// empty list when the network is down, which looks like "no data" and sends
/// people looking in the wrong place.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    required this.value,
    required this.builder,
    required this.onRetry,
    this.isEmpty,
    this.emptyTitle = 'Nothing here yet',
    this.emptyMessage,
    this.emptyIcon = Icons.inbox_outlined,
    super.key,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback onRetry;

  /// Lets a screen say what "empty" means for its own data.
  final bool Function(T data)? isEmpty;
  final String emptyTitle;
  final String? emptyMessage;
  final IconData emptyIcon;

  @override
  Widget build(BuildContext context) {
    return value.when(
      skipLoadingOnRefresh: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => ErrorState(error: error, onRetry: onRetry),
      data: (data) {
        if (isEmpty?.call(data) ?? false) {
          return EmptyState(
            icon: emptyIcon,
            title: emptyTitle,
            message: emptyMessage,
          );
        }
        return builder(data);
      },
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({required this.error, required this.onRetry, super.key});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // An unreachable API during development almost always means the backend is
    // not running, so say that rather than showing a socket error.
    final (title, detail) = switch (error) {
      // On the web these are two different problems that look identical from
      // here: the browser deliberately hides whether a request failed because
      // nothing answered or because CORS rejected it, so the message names
      // both rather than guessing and sending someone the wrong way.
      ApiUnreachable(:final baseUrl) => (
        'Cannot reach the API',
        kIsWeb
            ? 'Nothing answered at $baseUrl, or the browser blocked the '
                  'request because this page is not an allowed origin.\n'
                  'Check the API is running, and that its CORS policy accepts '
                  'this address.'
            : 'Nothing answered at $baseUrl.\n'
                  'Start it with: dotnet run --project backend/src/CafeOps.Api',
      ),
      ApiException(:final statusCode, :final message)
          when statusCode == 401 || statusCode == 403 =>
        ('Not allowed', message),
      ApiException(:final message) => ('Something went wrong', message),
      _ => ('Something went wrong', error.toString()),
    };

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 40, color: scheme.error),
              const SizedBox(height: 12),
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 44, color: scheme.outline),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (message != null) ...[
                const SizedBox(height: 6),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
              if (action != null) const SizedBox(height: 20),
              ?action,
            ],
          ),
        ),
      ),
    );
  }
}

/// A small coloured label, used for order and line states.
class StatusChip extends StatelessWidget {
  const StatusChip({
    required this.label,
    required this.tone,
    this.icon,
    super.key,
  });

  final String label;
  final ChipTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final (background, foreground) = switch (tone) {
      ChipTone.neutral => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      ChipTone.info => (scheme.secondaryContainer, scheme.onSecondaryContainer),
      ChipTone.warning => (scheme.warningSurface, scheme.onWarningSurface),
      ChipTone.success => (scheme.successSurface, scheme.success),
      ChipTone.danger => (scheme.errorContainer, scheme.onErrorContainer),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: foreground),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

enum ChipTone { neutral, info, warning, success, danger }

/// Shows a message in a snack bar, styled by whether it went well.
void showToast(BuildContext context, String message, {bool isError = false}) {
  if (!context.mounted) {
    return;
  }

  final scheme = Theme.of(context).colorScheme;

  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? scheme.errorContainer : null,
        showCloseIcon: isError,
        // Stock shortages list several ingredients, which needs reading time.
        duration: Duration(seconds: isError ? 6 : 3),
      ),
    );
}

/// A section heading used on the manager screens.
class SectionHeader extends StatelessWidget {
  const SectionHeader({required this.title, this.trailing, super.key});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.2),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
