import 'interface_strings.dart';

import 'package:flutter/material.dart';

/// Shared presentation for backup summaries, results and bounded record lists.
class BackupSummary extends StatelessWidget {
  const BackupSummary(this.rows, {super.key});
  final List<(String, String)> rows;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: LayoutBuilder(
                builder: (context, box) {
                  final large =
                      MediaQuery.textScalerOf(context).scale(16) > 20 ||
                      box.maxWidth < 280;
                  final title = Text(
                    label,
                    style: Theme.of(context).textTheme.bodySmall,
                  );
                  final detail = Text(
                    value,
                    style: Theme.of(context).textTheme.titleMedium,
                  );
                  return large
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [title, const SizedBox(height: 4), detail],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: title),
                            const SizedBox(width: 16),
                            Flexible(child: detail),
                          ],
                        );
                },
              ),
            ),
        ],
      ),
    ),
  );
}

class BackupNotice extends StatelessWidget {
  const BackupNotice(this.message, {super.key, this.warning = false});
  final String message;
  final bool warning;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(
            width: 3,
            color: warning
                ? Theme.of(context).colorScheme.error
                : Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
      child: Text(context.domainText(message)),
    ),
  );
}

class BackupRecords<T> extends StatefulWidget {
  const BackupRecords({
    super.key,
    required this.items,
    required this.label,
    required this.builder,
    this.searchLabel = '搜索记录',
  });
  final List<T> items;
  final String Function(T) label;
  final Widget Function(T) builder;
  final String searchLabel;
  @override
  State<BackupRecords<T>> createState() => _BackupRecordsState<T>();
}

class _BackupRecordsState<T> extends State<BackupRecords<T>> {
  String _query = '';
  int _page = 0;
  @override
  Widget build(BuildContext context) {
    final items = widget.items
        .where(
          (x) => widget.label(x).toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    final pages = (items.length / 8).ceil().clamp(1, 1 << 30);
    final page = _page.clamp(0, pages - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.items.length > 8)
          TextField(
            key: const PageStorageKey('backup-records-search'),
            decoration: InputDecoration(
              labelText: context.tr(widget.searchLabel),
              prefixIcon: const Icon(Icons.search),
            ),
            onChanged: (v) => setState(() {
              _query = v;
              _page = 0;
            }),
          ),
        if (items.isEmpty)
          Padding(
            padding: EdgeInsets.all(16),
            child: Text(context.tr('没有符合条件的记录')),
          ),
        ...items.skip(page * 8).take(8).map(widget.builder),
        if (pages > 1)
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                onPressed: page == 0
                    ? null
                    : () => setState(() => _page = page - 1),
                child: Text(context.tr('上一页')),
              ),
              Text(
                context.tr('{0} / {1} · 共 {2} 条', [
                  page + 1,
                  pages,
                  items.length,
                ]),
              ),
              TextButton(
                onPressed: page == pages - 1
                    ? null
                    : () => setState(() => _page = page + 1),
                child: Text(context.tr('下一页')),
              ),
            ],
          ),
      ],
    );
  }
}
