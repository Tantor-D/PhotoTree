import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The few shared visual values used by PhotoTree's navigation and overlays.
/// Photo content and application state do not belong to this component.
abstract final class PhotoTreeStyle {
  static const lightBackground = Color(0xFFF5F5F7);
  static const darkBackground = Color(0xFF111113);
  static const lightSurface = Color(0xFFFFFFFF);
  static const darkSurface = Color(0xFF242426);
  static const lightText = Color(0xFF1C1C1E);
  static const darkText = Color(0xFFF5F5F7);
  static const lightSecondary = Color(0xFF505055);
  static const darkSecondary = Color(0xFFC2C2C7);
  static const lightAccent = Color(0xFF0064D2);
  static const darkAccent = Color(0xFF78B5FF);
  static const lightDanger = Color(0xFFBC2433);
  static const darkDanger = Color(0xFFFF9AA3);
  static const toolbarRadius = BorderRadius.all(Radius.circular(20));
  static const panelRadius = BorderRadius.all(Radius.circular(24));
  static const selectionRadius = BorderRadius.all(Radius.circular(12));
}

// Edge-to-edge uses the page's own background. Older Android navigation bars
// can sit outside that canvas, so give them the matching opaque fallback too.
SystemUiOverlayStyle photoTreeSystemUiStyle(
  Brightness brightness, {
  Color? navigationBarColor,
}) {
  final icons = brightness == Brightness.dark
      ? Brightness.light
      : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: brightness,
    statusBarIconBrightness: icons,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarColor:
        navigationBarColor ??
        (brightness == Brightness.dark
            ? PhotoTreeStyle.darkBackground
            : PhotoTreeStyle.lightBackground),
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: icons,
    systemNavigationBarContrastEnforced: false,
  );
}

/// Fallback for custom navigation chrome; route-local AppBars and the viewer
/// supply their own status-bar annotation where they cover this region.
Widget photoTreeAppBuilder(BuildContext context, Widget? child) =>
    AnnotatedRegion<SystemUiOverlayStyle>(
      value: photoTreeSystemUiStyle(Theme.of(context).brightness),
      child: child ?? const SizedBox.shrink(),
    );

ThemeData photoTreeTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final surface = dark
      ? PhotoTreeStyle.darkSurface
      : PhotoTreeStyle.lightSurface;
  final text = dark ? PhotoTreeStyle.darkText : PhotoTreeStyle.lightText;
  final secondary = dark
      ? PhotoTreeStyle.darkSecondary
      : PhotoTreeStyle.lightSecondary;
  final colors =
      ColorScheme.fromSeed(
        seedColor: PhotoTreeStyle.lightAccent,
        brightness: brightness,
      ).copyWith(
        primary: dark ? PhotoTreeStyle.darkAccent : PhotoTreeStyle.lightAccent,
        onPrimary: dark ? PhotoTreeStyle.darkBackground : Colors.white,
        primaryContainer: dark
            ? const Color(0xFF243B56)
            : const Color(0xFFE7F0FF),
        onPrimaryContainer: dark
            ? PhotoTreeStyle.darkAccent
            : PhotoTreeStyle.lightAccent,
        surface: surface,
        onSurface: text,
        onSurfaceVariant: secondary,
        error: dark ? PhotoTreeStyle.darkDanger : PhotoTreeStyle.lightDanger,
        onError: dark ? PhotoTreeStyle.darkSurface : Colors.white,
      );
  TextStyle role(double size, double line, FontWeight weight, [Color? color]) =>
      TextStyle(
        fontFamily: 'Inter',
        fontFamilyFallback: const ['Noto Sans SC'],
        fontSize: size,
        height: line / size,
        fontWeight: weight,
        letterSpacing: 0,
        color: color ?? text,
      );
  final body = role(16, 23, FontWeight.w400);
  final auxiliary = role(12, 17, FontWeight.w400, secondary);
  final button = role(16, 22, FontWeight.w600);
  final title = role(19, 26, FontWeight.w600);
  final confirmation = role(17, 24, FontWeight.w600);
  final section = role(14, 19, FontWeight.w600);
  final base = ThemeData(
    useMaterial3: true,
    fontFamily: 'Inter',
    fontFamilyFallback: const ['Noto Sans SC'],
    brightness: brightness,
    colorScheme: colors,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    scaffoldBackgroundColor: dark
        ? PhotoTreeStyle.darkBackground
        : PhotoTreeStyle.lightBackground,
  );
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      titleLarge: title,
      titleMedium: confirmation,
      titleSmall: section,
      bodyLarge: body,
      bodyMedium: body,
      bodySmall: auxiliary,
      labelLarge: button,
      labelMedium: section,
      labelSmall: auxiliary,
    ),
    cardTheme: CardThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dividerTheme: DividerThemeData(
      color: dark ? const Color(0xFF48484C) : const Color(0xFFDADADD),
      thickness: 1,
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      minTileHeight: 48,
      horizontalTitleGap: 12,
      titleTextStyle: body,
      subtitleTextStyle: auxiliary,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      contentTextStyle: body.copyWith(
        color: dark ? PhotoTreeStyle.lightText : PhotoTreeStyle.darkText,
      ),
    ),
    appBarTheme: AppBarThemeData(
      systemOverlayStyle: photoTreeSystemUiStyle(brightness),
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      foregroundColor: text,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: title,
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        textStyle: button.copyWith(fontWeight: FontWeight.w500),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        textStyle: button,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        textStyle: button.copyWith(fontWeight: FontWeight.w500),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: PhotoTreeStyle.panelRadius,
      ),
      titleTextStyle: confirmation,
      contentTextStyle: body,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: const Color(0x1A000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: dark ? const Color(0x24FFFFFF) : const Color(0x1F172033),
        ),
      ),
      textStyle: body,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: surface,
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
  );
}

/// A clipped, local glass surface. Callers disable [enabled] when a second
/// overlay covers it, so overlapping surfaces need not filter the same content.
/// Disabling blur keeps the material; reduced motion and important body content
/// use an opaque surface instead. This widget never owns navigation or state.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius,
    this.enabled = true,
    this.dark = false,
    this.highOpacity = false,
    this.opacity,
  }) : assert(opacity == null || (opacity >= 0 && opacity <= 1));

  final Widget child;
  final BorderRadius? borderRadius;
  final bool enabled;
  final bool dark;
  final bool highOpacity;

  /// Only the sidebar supplies its user preference. This changes the surface
  /// fill, never the opacity of text, icons, thumbnails or other descendants.
  final double? opacity;

  @override
  Widget build(BuildContext context) {
    final isDark = dark || Theme.of(context).brightness == Brightness.dark;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final radius = borderRadius ?? PhotoTreeStyle.toolbarRadius;
    final color = isDark
        ? PhotoTreeStyle.darkSurface
        : PhotoTreeStyle.lightSurface;
    final alpha = reduced || highOpacity ? 1.0 : (opacity ?? .94);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: isDark ? const Color(0x33000000) : const Color(0x14000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          enabled: enabled && !reduced && !highOpacity && alpha < 1,
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color.withValues(alpha: alpha),
              borderRadius: radius,
              border: Border.all(
                color: isDark
                    ? const Color(0x1FFFFFFF)
                    : const Color(0x14000000),
              ),
            ),
            child: Material(type: MaterialType.transparency, child: child),
          ),
        ),
      ),
    );
  }
}

/// Existing secondary pages retain Android's back navigation. Measure the title
/// with the same style as rendering, so large text gets space rather than clips.
AppBar photoTreePageBar(
  BuildContext context, {
  required String title,
  Widget? leading,
  List<Widget>? actions,
}) {
  final scaler = MediaQuery.textScalerOf(context);
  final style =
      Theme.of(context).appBarTheme.titleTextStyle ??
      Theme.of(context).textTheme.titleLarge!;
  final leadingWidth = leading == null ? 56.0 : scaler.scale(16) * 2 + 32;
  final actionWidth = (actions?.length ?? 0) * (scaler.scale(16) * 4 + 32);
  final width =
      (MediaQuery.sizeOf(context).width - leadingWidth - actionWidth - 32)
          .clamp(48.0, double.infinity);
  final painter = TextPainter(
    text: TextSpan(text: title, style: style),
    textScaler: scaler,
    textDirection: Directionality.of(context),
  )..layout(maxWidth: width);
  final height = (painter.height.ceilToDouble() + 16).clamp(
    56.0,
    double.infinity,
  );
  painter.dispose();
  return AppBar(
    title: Text(
      title,
      softWrap: true,
      overflow: TextOverflow.visible,
      textScaler: scaler,
    ),
    leading: leading,
    leadingWidth: leadingWidth,
    actions: actions,
    toolbarHeight: height,
  );
}
