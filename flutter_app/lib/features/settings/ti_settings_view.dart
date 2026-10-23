import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../domain/models.dart';
import 'fluent_controls.dart';
import 'settings_catalog.dart';
import 'ti_settings_schema.dart';
import 'ti_settings_strings.dart';

/// Builds the bespoke widget for a [TiSettingBlock].
typedef TiSettingsBlockBuilder = Widget Function(
  BuildContext context,
  TiSettingBlock block,
  AppConfig config,
  ValueChanged<AppConfig> onChanged,
);

/// Asks the host for a font family. Returns null when the user cancels.
typedef TiFontPicker = Future<String?> Function(
  TiSettingSpec spec,
  String current,
);

/// Renders a declared settings catalog.
///
/// The page owns nothing but the chrome: search, the changed counter, reset,
/// import and export. Every row comes from the catalog, so adding a setting is
/// one declaration and no widget code.
class TiSettingsView extends StatefulWidget {
  const TiSettingsView({
    super.key,
    required this.catalog,
    required this.config,
    required this.onChanged,
    this.blockBuilders = const {},
    this.onPickFont,
    this.trailing,
    this.showSearch = true,
    this.anchorKeys,
  });

  final TiSettingsCatalog catalog;
  final AppConfig config;

  /// Called on every edit. There is no save button: the caller applies the
  /// value immediately.
  final ValueChanged<AppConfig> onChanged;

  final Map<String, TiSettingsBlockBuilder> blockBuilders;
  final TiFontPicker? onPickFont;

  /// Extra toolbar actions owned by the host.
  final Widget? trailing;

  /// Turn off when the host already offers a search box over the whole page,
  /// so the user does not get two of them.
  final bool showSearch;

  /// Shared anchor table owned by the host page. When a search result names an
  /// anchor, the page looks it up here to scroll the row into view; the view
  /// registers one key per declared anchor on first build.
  final Map<String, GlobalKey>? anchorKeys;

  @override
  State<TiSettingsView> createState() => _TiSettingsViewState();
}

class _TiSettingsViewState extends State<TiSettingsView> {
  final _search = TextEditingController();
  final Set<String> _expanded = {};
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  TiSettingsStrings get _strings =>
      TiSettingsStrings(Localizations.localeOf(context).languageCode == 'zh');

  bool get _searching => widget.showSearch && _query.trim().isNotEmpty;

  List<TiSettingGroup> get _groups => _searching
      ? widget.catalog.search(_query)
      : widget.catalog
            .orderedGroups(where: (group) => group.visibleIn(widget.config))
            .toList();

  bool _expandedFor(TiSettingGroup group) {
    if (_searching) return true;
    if (!group.isCollapsible) return true;
    return _expanded.contains(group.id);
  }

  void _toggle(TiSettingGroup group) {
    setState(() {
      if (!_expanded.remove(group.id)) _expanded.add(group.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = _strings;
    final groups = _groups;
    final changed = widget.catalog.modifiedCount(widget.config);
    final restart = widget.catalog.allSpecs
        .where((spec) => spec.needsRestart && spec.isModified(widget.config))
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(strings, changed),
        if (restart > 0) _restartBanner(strings, restart),
        Expanded(
          child: groups.isEmpty
              ? _empty(strings, _searching)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
                  children: [
                    for (final group in groups) _groupCard(strings, group),
                  ],
                ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ chrome
  Widget _toolbar(TiSettingsStrings strings, int changed) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
    child: Row(
      children: [
        if (widget.showSearch) ...[
          Expanded(
            child: FTextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: strings.search,
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          const SizedBox(width: 8),
        ] else
          const Spacer(),
        if (changed > 0)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              '${strings.changed} $changed ${strings.unit}'.trim(),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (widget.trailing != null) widget.trailing!,
        _menu(strings, changed),
      ],
    ),
  );

  Widget _menu(TiSettingsStrings strings, int changed) =>
      PopupMenuButton<String>(
        tooltip: strings.more,
        icon: const Icon(Icons.more_vert_rounded, size: 20),
        onSelected: (value) => switch (value) {
          'reset' => _resetAll(strings),
          'export' => _export(strings),
          'import' => _import(strings),
          _ => null,
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'reset',
            enabled: changed > 0,
            child: Text(strings.resetAll),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(value: 'export', child: Text(strings.exportJson)),
          PopupMenuItem(value: 'import', child: Text(strings.importJson)),
        ],
      );

  Widget _restartBanner(TiSettingsStrings strings, int count) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        Icon(
          Icons.restart_alt_rounded,
          size: 18,
          color: Theme.of(context).colorScheme.onSecondaryContainer,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            strings.restartBanner(count),
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _empty(TiSettingsStrings strings, bool searching) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        searching ? strings.searchEmpty : strings.noSettings,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 13,
        ),
      ),
    ),
  );

  // ------------------------------------------------------------------ groups
  Widget _groupCard(TiSettingsStrings strings, TiSettingGroup group) {
    final expanded = _expandedFor(group);
    final modified = group.modifiedCount(widget.config);
    final showBadge = group.level != TiSettingLevel.common && !_searching;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: group.isCollapsible ? () => _toggle(group) : null,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  group.title,
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                              ),
                              if (showBadge) ...[
                                const SizedBox(width: 8),
                                _pill(
                                  group.level == TiSettingLevel.advanced
                                      ? strings.advanced
                                      : strings.experimental,
                                ),
                              ],
                            ],
                          ),
                          if (group.description != null) ...[
                            const SizedBox(height: 3),
                            Text(
                              group.description!,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (modified > 0)
                      IconButton(
                        tooltip: strings.resetGroup,
                        iconSize: 18,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => widget.onChanged(
                          widget.catalog.resetGroup(widget.config, group),
                        ),
                        icon: const Icon(Icons.settings_backup_restore_rounded),
                      ),
                    if (group.isCollapsible)
                      Icon(
                        expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 20,
                      ),
                  ],
                ),
              ),
            ),
            if (expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final item in group.items) _item(strings, item),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _pill(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _item(TiSettingsStrings strings, TiSettingItem item) {
    final anchor = switch (item) {
      TiSettingSpec spec => spec.anchor,
      TiSettingBlock block => block.anchor,
    };
    final key = _anchorKey(anchor);

    final child = switch (item) {
      TiSettingSpec spec => _specRow(strings, spec),
      TiSettingBlock block =>
        widget.blockBuilders[block.id]?.call(
              context,
              block,
              widget.config,
              widget.onChanged,
            ) ??
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                block.title,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
    };

    return key == null ? child : KeyedSubtree(key: key, child: child);
  }

  GlobalKey? _anchorKey(String? anchor) {
    final table = widget.anchorKeys;
    if (table == null || anchor == null) return null;
    return table.putIfAbsent(anchor, GlobalKey.new);
  }

  // -------------------------------------------------------------------- rows
  Widget _specRow(TiSettingsStrings strings, TiSettingSpec spec) {
    if (!(spec.visible?.call(widget.config) ?? true)) {
      return const SizedBox.shrink();
    }
    final modified = spec.isModified(widget.config);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingRow(
          title: spec.label,
          description: spec.hint,
          controlWidth: _controlWidth(spec.type),
          control: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (modified)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              Flexible(child: _control(strings, spec)),
            ],
          ),
        ),
        if (spec.needsRestart && modified)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              strings.needsRestart,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const Divider(height: 1),
      ],
    );
  }

  double _controlWidth(TiSettingType type) => switch (type) {
    TiSettingType.slider => 220,
    TiSettingType.segment => 210,
    TiSettingType.select => 180,
    TiSettingType.toggle => 52,
    TiSettingType.stepper => 132,
    _ => 180,
  };

  Widget _control(TiSettingsStrings strings, TiSettingSpec spec) {
    final value = spec.read(widget.config);

    switch (spec.type) {
      case TiSettingType.toggle:
        return FSwitch(
          value: value == true,
          onChanged: (next) =>
              widget.onChanged(spec.write(widget.config, next)),
        );

      case TiSettingType.segment:
        final current = '${value ?? spec.defaultValue}';
        return SegmentedButton<String>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: [
            for (final option in spec.options)
              ButtonSegment(value: option.value, label: Text(option.label)),
          ],
          selected: {current},
          onSelectionChanged: (selection) =>
              widget.onChanged(spec.write(widget.config, selection.single)),
        );

      case TiSettingType.select:
        final current = '${value ?? spec.defaultValue}';
        return FDropdown<String>(
          key: ValueKey('${spec.key}:$current'),
          initialValue: current,
          isExpanded: true,
          items: [
            for (final option in spec.options)
              FDropdownItem(value: option.value, child: Text(option.label)),
          ],
          onChanged: (next) {
            if (next != null) {
              widget.onChanged(spec.write(widget.config, next));
            }
          },
        );

      case TiSettingType.slider:
        final min = spec.min ?? 0;
        final max = spec.max ?? 1;
        final step = spec.step ?? 1;
        final numeric = (value as num?)?.toDouble() ?? min;
        final divisions = step > 0 ? ((max - min) / step).round() : null;
        return Row(
          children: [
            Expanded(
              child: FSlider(
                value: numeric.clamp(min, max).toDouble(),
                min: min,
                max: max,
                divisions: divisions,
                label: '${_format(numeric, step)}${spec.unit ?? ''}',
                onChanged: (next) =>
                    widget.onChanged(spec.write(widget.config, next)),
              ),
            ),
            SizedBox(
              width: 62,
              child: Text(
                '${_format(numeric, step)}${spec.unit ?? ''}',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        );

      case TiSettingType.stepper:
        final numeric = (value as num?)?.toDouble() ?? 0;
        final step = spec.step ?? 1;
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: () => widget.onChanged(
                spec.write(
                  widget.config,
                  (numeric - step).clamp(
                    spec.min ?? double.negativeInfinity,
                    spec.max ?? double.infinity,
                  ),
                ),
              ),
              icon: const Icon(Icons.remove_rounded),
            ),
            SizedBox(
              width: 56,
              child: Text(
                '${_format(numeric, step)}${spec.unit ?? ''}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: () => widget.onChanged(
                spec.write(
                  widget.config,
                  (numeric + step).clamp(
                    spec.min ?? double.negativeInfinity,
                    spec.max ?? double.infinity,
                  ),
                ),
              ),
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        );

      case TiSettingType.text:
        return _TiTextField(
          key: ValueKey(spec.key),
          value: '${value ?? spec.defaultValue ?? ''}',
          onChanged: (next) =>
              widget.onChanged(spec.write(widget.config, next)),
        );

      case TiSettingType.font:
        final current = '${value ?? spec.defaultValue ?? ''}';
        return FButton(
          onPressed: widget.onPickFont == null
              ? null
              : () async {
                  final picked = await widget.onPickFont!(spec, current);
                  if (picked != null) {
                    widget.onChanged(spec.write(widget.config, picked));
                  }
                },
          child: Text(current, overflow: TextOverflow.ellipsis),
        );

      case TiSettingType.color:
      case TiSettingType.path:
      case TiSettingType.shortcut:
        return Text(
          strings.unsupportedControl,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
    }
  }

  String _format(double value, double step) =>
      step >= 1 ? value.round().toString() : value.toStringAsFixed(1);

  // ------------------------------------------------------------------ actions
  Future<void> _resetAll(TiSettingsStrings strings) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => FAlertDialog(
        title: Text(strings.resetAll),
        content: Text(strings.resetAllConfirm),
        actions: [
          FTextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(strings.cancel),
          ),
          FButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(strings.confirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    widget.onChanged(widget.catalog.resetAll(widget.config));
  }

  Future<void> _export(TiSettingsStrings strings) async {
    final values = widget.catalog.export(widget.config);
    final payload = const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'values': values,
    });
    final location = await getSaveLocation(
      suggestedName: 'settings.json',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (location == null) return;
    await File(location.path).writeAsString(payload);
    if (!mounted) return;
    _notify(
      values.isEmpty
          ? strings.exportEmpty
          : '${strings.exportDone} · ${location.path}',
    );
  }

  Future<void> _import(TiSettingsStrings strings) async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (file == null) return;

    Map<String, Object?> values;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) throw const FormatException('not an object');
      final inner = decoded['values'];
      values = inner is Map
          ? inner.cast<String, Object?>()
          : decoded.cast<String, Object?>();
    } catch (_) {
      if (mounted) _notify(strings.importFailed);
      return;
    }

    final result = widget.catalog.import(widget.config, values);
    widget.onChanged(result.config);
    if (!mounted) return;
    final applied = values.length - result.skipped.length;
    _notify(
      result.skipped.isEmpty
          ? '${strings.importDone} $applied'
          : '${strings.importDone} $applied · ${strings.importSkipped} '
                '${result.skipped.length}',
    );
  }

  void _notify(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }
}

class _TiTextField extends StatefulWidget {
  const _TiTextField({super.key, required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_TiTextField> createState() => _TiTextFieldState();
}

class _TiTextFieldState extends State<_TiTextField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(_TiTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep the caret when the edit came from this field; adopt the outside
    // value when something else changed it (reset, import).
    if (widget.value != oldWidget.value && widget.value != _controller.text) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FTextField(
    controller: _controller,
    onChanged: widget.onChanged,
    decoration: const InputDecoration(isDense: true),
  );
}
