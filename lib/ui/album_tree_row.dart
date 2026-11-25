import 'package:flutter/material.dart';

/// Shared presentation only; browsing and destination selection own their state.
class AlbumTreeRow extends StatelessWidget {
  const AlbumTreeRow({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.titleGap = 12,
    this.trailing,
    this.selected = false,
    this.onTap,
    this.enabled = true,
    this.foregroundBuilder,
  });
  final Widget Function(Widget)? foregroundBuilder;
  Widget _back(Widget child) => foregroundBuilder?.call(child) ?? child;
  final Widget leading;
  final double titleGap;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool selected, enabled;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 120);
    final foreground = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface;
    return Semantics(
      selected: selected,
      enabled: enabled,
      child: AnimatedContainer(
        duration: duration,
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  if (selected)
                    Positioned(
                      left: 3,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: foreground,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: const SizedBox(width: 3, height: 20),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Row(
                      children: [
                        TweenAnimationBuilder<Color?>(
                          duration: duration,
                          tween: ColorTween(begin: foreground, end: foreground),
                          child: leading,
                          builder: (context, color, child) => IconTheme(
                            data: IconThemeData(color: color, size: 24),
                            child: child!,
                          ),
                        ),
                        SizedBox(width: titleGap),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Reserve the emphasized title's line breaks so
                                // toggling selection never moves neighboring rows.
                                _back(
                                  Stack(
                                    children: [
                                      ExcludeSemantics(
                                        child: RichText(
                                          textScaler: MediaQuery.textScalerOf(
                                            context,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          text: TextSpan(
                                            text: title,
                                            style: theme.textTheme.bodyMedium!
                                                .copyWith(
                                                  fontWeight: FontWeight.w600,
                                                  color: Colors.transparent,
                                                ),
                                          ),
                                        ),
                                      ),
                                      Positioned.fill(
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: AnimatedDefaultTextStyle(
                                            duration: duration,
                                            style: theme.textTheme.bodyMedium!
                                                .copyWith(
                                                  color: enabled
                                                      ? foreground
                                                      : theme.disabledColor,
                                                  fontWeight: selected
                                                      ? FontWeight.w600
                                                      : FontWeight.w400,
                                                ),
                                            child: Text(
                                              title,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (subtitle != null && subtitle!.isNotEmpty)
                                  _back(
                                    Text(
                                      subtitle!,
                                      style: theme.textTheme.bodySmall!
                                          .copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        if (trailing != null)
                          trailing!
                        else
                          const SizedBox(width: 12),
                      ],
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
