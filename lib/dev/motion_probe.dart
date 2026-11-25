import '../ui/interface_strings.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/motion.dart';

/// A separate development surface. It never represents or accesses a photo.
class MotionProbePage extends StatelessWidget {
  const MotionProbePage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final instructions = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr('拖动 · 松手回弹 · 中途接管'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(context.tr('拖动卡片后松手；回弹途中再次按住，即可从当前位置继续拖动。')),
      ],
    );
    final footer = Text(
      context.tr('开发验证 · 本页不读取照片'),
      style: Theme.of(context).textTheme.bodySmall,
    );
    final sample = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cardWidth = math.min(172.0, constraints.maxWidth * .56);
          final cardHeight = math.min(180.0, constraints.maxHeight * .60);
          return Stack(
            alignment: Alignment.center,
            children: [
              Icon(Icons.add, color: colors.outlineVariant, size: 32),
              DragSpring(
                maxOffset: Offset(
                  math.max(0.0, (constraints.maxWidth - cardWidth) / 2 - 12),
                  math.max(0.0, (constraints.maxHeight - cardHeight) / 2 - 12),
                ),
                child: SizedBox(
                  key: const ValueKey('motion-sample-card'),
                  width: cardWidth,
                  height: cardHeight,
                  child: Card(
                    margin: EdgeInsets.zero,
                    color: colors.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            context.tr('示例卡片\n不是真实照片'),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: colors.onPrimaryContainer),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('动效验证'))),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Landscape keeps the gesture surface visible beside the text.
              // Text can scroll independently when the system font is large.
              if (constraints.maxWidth >= 560 &&
                  constraints.maxWidth > constraints.maxHeight) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 2,
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            instructions,
                            const SizedBox(height: 16),
                            footer,
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(flex: 3, child: sample),
                  ],
                );
              }
              // Only the instructions scroll. The sample has no scrolling
              // ancestor competing for its vertical drag recognizer.
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * .36,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          instructions,
                          const SizedBox(height: 12),
                          footer,
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(child: sample),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
