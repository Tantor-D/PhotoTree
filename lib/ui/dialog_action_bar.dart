import 'package:flutter/material.dart';

/// Presentation only. Callers retain ownership of confirmation and execution.
class DialogActionBar extends StatelessWidget {
  const DialogActionBar({
    super.key,
    this.dismissLabel,
    this.onDismiss,
    this.actionLabel,
    this.onAction,
    this.actionKey,
    this.destructive = false,
    this.tonal = false,
  });
  final String? dismissLabel, actionLabel;
  final VoidCallback? onDismiss, onAction;
  final Key? actionKey;
  final bool destructive, tonal;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final theme = Theme.of(context);
      final scaler = MediaQuery.textScalerOf(context);
      final style = theme.textTheme.labelLarge!;
      bool fits(String? label) {
        if (label == null) return true;
        final painter = TextPainter(
          text: TextSpan(text: label, style: style),
          textDirection: Directionality.of(context),
          textScaler: scaler,
        )..layout();
        final fits =
            painter.width + 32 <= (box.maxWidth - (tonal ? 40 : 1)) / 2;
        painter.dispose();
        return fits;
      }

      final vertical =
          scaler.scale(16) >= 16 * 1.3 ||
          !fits(dismissLabel) ||
          !fits(actionLabel);
      Widget button(
        String label,
        VoidCallback? onPressed, {
        bool primary = false,
      }) => TextButton(
        key: primary ? actionKey : null,
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: tonal ? const StadiumBorder() : const RoundedRectangleBorder(),
          backgroundColor: tonal
              ? (primary && destructive
                    ? theme.colorScheme.error.withValues(alpha: .12)
                    : theme.colorScheme.onSurface.withValues(alpha: .06))
              : null,
          foregroundColor: primary && destructive
              ? theme.colorScheme.error
              : tonal && !primary
              ? theme.colorScheme.onSurface
              : null,
          textStyle: style.copyWith(
            fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
        child: Text(label, textAlign: TextAlign.center),
      );
      final dismiss = dismissLabel == null
          ? null
          : button(dismissLabel!, onDismiss);
      final action = actionLabel == null
          ? null
          : button(actionLabel!, onAction, primary: true);
      return Padding(
        padding: tonal
            ? const EdgeInsets.fromLTRB(16, 0, 16, 16)
            : EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!tonal) const Divider(),
            if (vertical || dismiss == null || action == null)
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?action,
                  if (action != null && dismiss != null)
                    tonal ? const SizedBox(height: 8) : const Divider(),
                  ?dismiss,
                ],
              )
            else
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: dismiss),
                    tonal
                        ? const SizedBox(width: 8)
                        : const VerticalDivider(width: 1),
                    Expanded(child: action),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// The app's ordinary confirmation family; tree pickers and forms stay separate.
class PhotoTreeConfirmation extends StatelessWidget {
  const PhotoTreeConfirmation({
    super.key,
    required this.title,
    required this.content,
    required this.dismissLabel,
    required this.onDismiss,
    required this.actionLabel,
    required this.onAction,
    this.destructive = false,
  });
  final Widget title, content;
  final String dismissLabel, actionLabel;
  final VoidCallback? onDismiss, onAction;
  final bool destructive;
  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(24),
    constraints: const BoxConstraints(maxWidth: 340),
    clipBehavior: Clip.antiAlias,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DefaultTextStyle(
                    style:
                        Theme.of(context).dialogTheme.titleTextStyle ??
                        Theme.of(context).textTheme.titleMedium!,
                    textAlign: TextAlign.center,
                    child: title,
                  ),
                  const SizedBox(height: 12),
                  content,
                ],
              ),
            ),
          ),
        ),
        DialogActionBar(
          dismissLabel: dismissLabel,
          onDismiss: onDismiss,
          actionLabel: actionLabel,
          onAction: onAction,
          destructive: destructive,
        ),
      ],
    ),
  );
}
