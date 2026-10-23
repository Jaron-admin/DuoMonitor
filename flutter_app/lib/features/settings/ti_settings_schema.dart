import '../../domain/models.dart';

/// The control a declared setting renders as.
///
/// The mapping is fixed by the settings contract: the declared type decides the
/// widget, never the call site. That is what stops every page from inventing
/// its own idea of how an enum should look.
enum TiSettingType {
  /// Two states -> switch.
  toggle,

  /// At most three options -> segmented buttons.
  segment,

  /// More than three options -> dropdown.
  select,

  /// Number with a range -> slider plus a readout.
  slider,

  /// Number without a range -> stepper.
  stepper,

  /// Free text -> input field.
  text,

  /// Colour -> picker.
  color,

  /// Key combination -> recorder.
  shortcut,

  /// File or folder -> selector.
  path,

  /// Font family -> picker.
  font,
}

/// How deep a setting hides. Everything above [common] starts collapsed.
enum TiSettingLevel { common, advanced, experimental }

/// Fixed section order. [feature] is the one soft slot: up to three groups,
/// rendered in declaration order between appearance and notifications.
enum TiSettingSection {
  general,
  appearance,
  feature,
  notifications,
  privacy,
  advanced,
  about,
}

class TiSettingOption {
  const TiSettingOption(this.value, this.label);

  final String value;
  final String label;
}

typedef TiSettingReader = Object? Function(AppConfig config);
typedef TiSettingWriter = AppConfig Function(AppConfig config, Object? value);

/// One entry in a group: either a declared setting or a block that keeps its
/// bespoke widget. Blocks exist because some panels (theme editor, price colour
/// rules, font preview) are genuinely custom; forcing them into a scalar would
/// be worse than letting them through.
sealed class TiSettingItem {
  const TiSettingItem();
}

final class TiSettingBlock extends TiSettingItem {
  const TiSettingBlock({
    required this.id,
    required this.title,
    this.anchor,
    this.payload,
  });

  final String id;
  final String title;

  /// Legacy anchor name used by the page-wide search to scroll here.
  final String? anchor;

  /// Handed to the builder registered for [id]; keeps this file free of any
  /// Flutter dependency.
  final Object? payload;
}

/// A single declared setting. Everything the page needs to render it, search
/// it, mark it as changed and reset it lives here - no widget code involved.
final class TiSettingSpec extends TiSettingItem {
  const TiSettingSpec({
    required this.key,
    required this.type,
    required this.label,
    required this.read,
    required this.write,
    this.hint,
    this.level = TiSettingLevel.common,
    this.defaultValue,
    this.options = const [],
    this.min,
    this.max,
    this.step,
    this.unit,
    this.needsRestart = false,
    this.visible,
    this.anchor,
  });

  /// Stable English key, e.g. `appearance.theme`. Never rename it after a
  /// release: a rename is a data migration for every existing install.
  final String key;

  final TiSettingType type;
  final String label;

  /// One plain sentence about the consequence, not a repeat of [label].
  final String? hint;

  final TiSettingLevel level;
  final Object? defaultValue;
  final List<TiSettingOption> options;
  final double? min;
  final double? max;
  final double? step;
  final String? unit;
  final bool needsRestart;

  /// Legacy anchor name used by the page-wide search to scroll here.
  final String? anchor;

  final TiSettingReader read;
  final TiSettingWriter write;

  /// Hide the row without removing the value, e.g. a control that only makes
  /// sense while another setting is off.
  final bool? Function(AppConfig config)? visible;

  /// True when the stored value differs from the declared default. Drives the
  /// per-row dot and the "changed N" counter.
  bool isModified(AppConfig config) {
    final current = read(config);
    if (current is num && defaultValue is num) {
      return (current - (defaultValue as num)).abs() > 1e-9;
    }
    return current != defaultValue;
  }

  /// Put the stored value back to the declared default.
  AppConfig reset(AppConfig config) => write(config, defaultValue);

  bool matches(String query) {
    if (query.isEmpty) return true;
    final needle = query.toLowerCase().trim();
    if (needle.isEmpty) return true;
    final haystack = [
      key,
      label,
      hint ?? '',
      ...options.map((option) => option.label),
    ].join(' ').toLowerCase();
    return haystack.contains(needle);
  }

  /// Declare a boolean setting.
  factory TiSettingSpec.toggle({
    required String key,
    required String label,
    required bool Function(AppConfig config) read,
    required AppConfig Function(AppConfig config, bool value) write,
    bool defaultValue = false,
    String? hint,
    TiSettingLevel level = TiSettingLevel.common,
    bool needsRestart = false,
    bool? Function(AppConfig config)? visible,
    String? anchor,
  }) => TiSettingSpec(
    key: key,
    anchor: anchor,
    type: TiSettingType.toggle,
    label: label,
    hint: hint,
    level: level,
    defaultValue: defaultValue,
    needsRestart: needsRestart,
    visible: visible,
    read: read,
    write: (config, value) => write(config, value == true),
  );

  /// Declare a choice. Three options or fewer render as segmented buttons, more
  /// than three as a dropdown - decided here so no page has to think about it.
  factory TiSettingSpec.choice({
    required String key,
    required String label,
    required List<TiSettingOption> options,
    required String Function(AppConfig config) read,
    required AppConfig Function(AppConfig config, String value) write,
    required String defaultValue,
    String? hint,
    TiSettingLevel level = TiSettingLevel.common,
    bool needsRestart = false,
    bool? Function(AppConfig config)? visible,
    String? anchor,
  }) {
    if (options.length < 2) {
      throw ArgumentError.value(key, 'options', 'a choice needs two options');
    }
    return TiSettingSpec(
      key: key,
      anchor: anchor,
      type: options.length <= 3 ? TiSettingType.segment : TiSettingType.select,
      label: label,
      hint: hint,
      level: level,
      defaultValue: defaultValue,
      options: options,
      needsRestart: needsRestart,
      visible: visible,
      read: read,
      write: (config, value) => write(config, '${value ?? defaultValue}'),
    );
  }

  /// Declare a bounded number. Always a slider plus a readout, because a
  /// bounded number typed into a box is a guessing game.
  factory TiSettingSpec.range({
    required String key,
    required String label,
    required double min,
    required double max,
    required double Function(AppConfig config) read,
    required AppConfig Function(AppConfig config, double value) write,
    required double defaultValue,
    double? step,
    String? unit,
    String? hint,
    TiSettingLevel level = TiSettingLevel.common,
    bool needsRestart = false,
    bool? Function(AppConfig config)? visible,
    String? anchor,
  }) => TiSettingSpec(
    key: key,
    anchor: anchor,
    type: TiSettingType.slider,
    label: label,
    hint: hint,
    level: level,
    defaultValue: defaultValue,
    min: min,
    max: max,
    step: step,
    unit: unit,
    needsRestart: needsRestart,
    visible: visible,
    read: read,
    write: (config, value) =>
        write(config, value is num ? value.toDouble() : defaultValue),
  );

  /// Declare a free-text setting.
  factory TiSettingSpec.text({
    required String key,
    required String label,
    required String Function(AppConfig config) read,
    required AppConfig Function(AppConfig config, String value) write,
    String defaultValue = '',
    String? hint,
    TiSettingLevel level = TiSettingLevel.common,
    bool needsRestart = false,
    bool? Function(AppConfig config)? visible,
    String? anchor,
  }) => TiSettingSpec(
    key: key,
    anchor: anchor,
    type: TiSettingType.text,
    label: label,
    hint: hint,
    level: level,
    defaultValue: defaultValue,
    needsRestart: needsRestart,
    visible: visible,
    read: read,
    write: (config, value) => write(config, '${value ?? defaultValue}'),
  );
}

/// A titled card of settings inside a section.
class TiSettingGroup {
  const TiSettingGroup({
    required this.id,
    required this.section,
    required this.title,
    this.description,
    this.level = TiSettingLevel.common,
    this.items = const [],
  });

  final String id;
  final TiSettingSection section;
  final String title;
  final String? description;

  /// The highest level among the items wins; a group declared as advanced
  /// starts collapsed even when its items are common.
  final TiSettingLevel level;

  final List<TiSettingItem> items;

  Iterable<TiSettingSpec> get specs => items.whereType<TiSettingSpec>();

  int modifiedCount(AppConfig config) =>
      specs.where((spec) => spec.isModified(config)).length;

  bool get isCollapsible => level != TiSettingLevel.common;

  bool visibleIn(AppConfig config) =>
      specs.any((spec) => spec.visible?.call(config) ?? true);
}

/// The declared page. Order is the contract: sections come out in
/// [TiSettingSection] order and groups in declaration order inside a section.
class TiSettingsCatalog {
  TiSettingsCatalog({required List<TiSettingGroup> groups})
    : groups = List.unmodifiable(groups) {
    final seen = <String>{};
    for (final group in this.groups) {
      for (final spec in group.specs) {
        if (!seen.add(spec.key)) {
          throw ArgumentError('duplicate setting key: ${spec.key}');
        }
      }
    }
  }

  final List<TiSettingGroup> groups;

  Iterable<TiSettingSpec> get allSpecs => groups.expand((group) => group.specs);

  /// Groups in render order: section order first, declaration order second.
  List<TiSettingGroup> orderedGroups({bool Function(TiSettingGroup)? where}) {
    final index = {
      for (final section in TiSettingSection.values) section: section.index,
    };
    final visible = groups
        .where((group) => where?.call(group) ?? true)
        .toList();
    visible.sort((a, b) {
      final bySection = index[a.section]!.compareTo(index[b.section]!);
      if (bySection != 0) return bySection;
      return groups.indexOf(a).compareTo(groups.indexOf(b));
    });
    return visible;
  }

  /// Rows that match a search, grouped. Matching ignores level so a hit inside
  /// a collapsed group still surfaces.
  List<TiSettingGroup> search(String query) {
    if (query.trim().isEmpty) return orderedGroups();
    final result = <TiSettingGroup>[];
    for (final group in orderedGroups()) {
      final hits = group.items.where((item) {
        return switch (item) {
          TiSettingSpec spec => spec.matches(query),
          TiSettingBlock block => block.title.toLowerCase().contains(
            query.toLowerCase().trim(),
          ),
        };
      }).toList();
      if (hits.isEmpty) continue;
      result.add(
        TiSettingGroup(
          id: group.id,
          section: group.section,
          title: group.title,
          description: group.description,
          level: TiSettingLevel.common,
          items: hits,
        ),
      );
    }
    return result;
  }

  int modifiedCount(AppConfig config) =>
      allSpecs.where((spec) => spec.isModified(config)).length;

  /// Reset one key, one group, or everything.
  AppConfig resetAll(AppConfig config) =>
      allSpecs.fold(config, (acc, spec) => spec.reset(acc));

  AppConfig resetGroup(AppConfig config, TiSettingGroup group) =>
      group.specs.fold(config, (acc, spec) => spec.reset(acc));

  /// Values only, keyed by declared key. Used by export.
  Map<String, Object?> export(AppConfig config) => {
    for (final spec in allSpecs)
      if (spec.isModified(config)) spec.key: spec.read(config),
  };

  /// Apply an exported map. Unknown keys are reported instead of rejected, so a
  /// file from a newer build still restores everything it shares.
  ({AppConfig config, List<String> skipped}) import(
    AppConfig config,
    Map<String, Object?> values,
  ) {
    var next = config;
    final known = {for (final spec in allSpecs) spec.key: spec};
    final skipped = <String>[];
    for (final entry in values.entries) {
      final spec = known[entry.key];
      if (spec == null) {
        skipped.add(entry.key);
        continue;
      }
      next = spec.write(next, entry.value);
    }
    return (config: next, skipped: skipped);
  }
}
