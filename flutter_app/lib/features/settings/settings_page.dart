import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'fluent_controls.dart';

import '../../app/app_controller.dart';
import '../../domain/models.dart';
import '../../domain/display_order_sync.dart';
import '../../domain/display_snapshot.dart';
import '../../l10n/metrics_strings.dart';
import 'system_monitor_settings.dart';
import 'taskbar_settings.dart';
import 'panel_layout_settings.dart';
import 'price_color_settings.dart';
import '../../data/storage_location.dart';
import '../../domain/refresh_price.dart';
import '../../l10n/l10n.dart';
import '../../platform/system_fonts.dart';
import '../../platform/header_image_store.dart';
import '../panel/display_row_view.dart';
import 'source_editor.dart';
import 'row_editor.dart';
import 'template_picker.dart';
import 'settings_catalog.dart';
import 'settings_theme_picker.dart';
import 'price_format_settings.dart';
import 'ti_settings_appearance.dart';
import 'ti_settings_view.dart';

part 'settings_dialogs.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    required this.onClose,
    this.onSaved,
    this.outsideClicks,
    this.initialSection = 0,
  });
  final AppController controller;
  final VoidCallback onClose;
  final VoidCallback? onSaved;
  final Stream<void>? outsideClicks;
  final int initialSection;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late AppConfig _rootDraft;
  DisplayTarget _target = DisplayTarget.floating;
  AppConfig get _draft => _rootDraft.displayFor(_target);
  bool get _compactHeight => MediaQuery.sizeOf(context).height < 480;

  /// Writes into the current target's slice of [_rootDraft].
  ///
  /// The order reconciliation lives in [syncDisplayOrder] rather than here: it
  /// used to be inlined, so every assignment in this 2.9k-line page could
  /// silently reorder the panel. Same behaviour, one explicit call site.
  set _draft(AppConfig value) {
    _rootDraft = _rootDraft.withDisplay(
      _target,
      syncDisplayOrder(_draft, value),
    );
  }

  int _section = 0;
  String _search = '';
  String _kind = 'all';
  String _provider = 'all';
  int _assetPage = 0;
  bool _catalogRequested = false;
  bool _saving = false;
  Future<bool>? _saveOperation;
  bool _pickingImage = false;
  bool _closing = false;
  bool _loadingDraft = false;
  int _draftRevision = 0;
  StreamSubscription<void>? _outsideClickSubscription;
  late final Future<bool> Function() _exitGuard;
  String? _error;
  final _scrollController = ScrollController();
  final _watchlistScrollController = ScrollController();
  final _settingsSearch = TextEditingController();
  final _assetSearch = TextEditingController();
  final Map<String, GlobalKey> _anchors = {};
  final Map<String, GlobalKey> _catalogRowKeys = {};
  final Map<String, Asset> _catalogSnapshot = {};
  String _settingsQuery = '';
  String? _highlightedAnchor;
  bool _storageExpanded = false;
  int _storageRevision = 0;
  bool _storageChanging = false;
  List<String> _fonts = [
    'Segoe UI',
    'Microsoft YaHei',
    'Arial',
    'Consolas',
    'Noto Sans',
    'sans-serif',
  ];
  final Set<String> _createdSecrets = {};

  /// How many top-level settings differ from what is saved.
  ///
  /// Memoised on identity: AppConfig is immutable, so any edit or save produces
  /// a new instance. The header and footer both ask for this on every build,
  /// and each miss serialises the whole config twice.
  int get _changedCount {
    final saved = widget.controller.config;
    if (identical(_changedMemoDraft, _rootDraft) &&
        identical(_changedMemoSaved, saved)) {
      return _changedMemo;
    }
    final draft = Map<String, Object?>.of(_rootDraft.toJson())
      ..remove('windowBounds');
    final savedJson = Map<String, Object?>.of(saved.toJson())
      ..remove('windowBounds');
    var count = 0;
    for (final key in draft.keys) {
      final before = draft[key] ?? const <String, Object?>{};
      final after = savedJson[key] ?? const <String, Object?>{};
      if (encodeJson(before) != encodeJson(after)) count++;
    }
    _changedMemo = count;
    _changedMemoDraft = _rootDraft;
    _changedMemoSaved = saved;
    return count;
  }

  bool get _dirty => _changedCount > 0;

  Object? _changedMemoDraft;
  Object? _changedMemoSaved;
  int _changedMemo = 0;

  @override
  void initState() {
    super.initState();
    _rootDraft = widget.controller.config;
    _resetCatalogOrder();
    widget.controller.catalog.addListener(_catalogChanged);
    _exitGuard = () => _requestLeave(exitApp: true);
    widget.controller.beforeExit = _exitGuard;
    _outsideClickSubscription = widget.outsideClicks?.listen((_) {
      unawaited(_requestLeave(exitApp: false));
    });
    _section = widget.initialSection.clamp(0, settingsCategories.length - 1);
    if (_section == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _loadCatalog();
        }
      });
    }
    widget.controller.host
        .getSystemFonts()
        .then((fonts) {
          if (mounted && fonts.isNotEmpty) setState(() => _fonts = fonts);
        })
        .catchError((Object _) {});
  }

  @override
  void dispose() {
    unawaited(_outsideClickSubscription?.cancel());
    widget.controller.catalog.removeListener(_catalogChanged);
    if (widget.controller.beforeExit == _exitGuard) {
      widget.controller.beforeExit = null;
    }
    _scrollController.dispose();
    _watchlistScrollController.dispose();
    _settingsSearch.dispose();
    _assetSearch.dispose();
    super.dispose();
  }

  void _commit(AppConfig value) {
    setState(() {
      if (_draft.language != value.language) _error = null;
      _draft = value;
    });
    widget.controller.previewAppearance(_rootDraft);
  }

  /// Writes a change that belongs to the config as a whole rather than to one
  /// display target. Everything the user can see goes through this or
  /// [_commit]; no widget assigns the draft directly any more.
  void _commitRoot(AppConfig next) {
    setState(() => _rootDraft = next);
    widget.controller.previewAppearance(_rootDraft);
  }

  Future<void> _close() async {
    await _requestLeave(exitApp: false);
  }

  Future<bool> _requestLeave({required bool exitApp}) async {
    if (!mounted ||
        _closing ||
        _pickingImage ||
        _loadingDraft ||
        _storageChanging) {
      return false;
    }
    // Editors and pickers own their draft until they return a result.
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _closing = true);
    try {
      // A manual save owns the current draft. Coalesce close requests behind
      // it; a failed write must keep both the window and its draft available.
      final pendingSave = _saveOperation;
      if (pendingSave != null && !await pendingSave) return false;
      if (!mounted) return false;
      if (_dirty) return await _save(closeSettings: !exitApp);
      await _clearUncommittedSecrets();
      if (!mounted) return false;
      widget.controller.clearAppearancePreview();
      if (exitApp) {
        setState(() => _rootDraft = widget.controller.config);
      } else {
        if (pendingSave != null) widget.onSaved?.call();
        widget.onClose();
      }
      return true;
    } finally {
      if (mounted) setState(() => _closing = false);
    }
  }

  Future<void> _saveAndStay() async {
    if (!mounted ||
        _closing ||
        _saving ||
        _pickingImage ||
        _loadingDraft ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    if (_dirty) await _save(closeSettings: false);
  }

  Future<void> _clearUncommittedSecrets() async {
    final committed = widget.controller.config.customSources
        .expand((source) => source.secretHeaderRefs.values)
        .toSet();
    for (final key in _createdSecrets.difference(committed)) {
      try {
        await widget.controller.secrets.delete(key);
      } catch (_) {}
    }
    _createdSecrets.clear();
  }

  Future<bool> _save({bool closeSettings = true}) {
    if (!mounted || _saving || _pickingImage || _loadingDraft) {
      return Future<bool>.value(false);
    }
    final operation = _commitDraft(closeSettings: closeSettings);
    _saveOperation = operation;
    return operation.whenComplete(() {
      if (identical(_saveOperation, operation)) _saveOperation = null;
    });
  }

  Future<bool> _commitDraft({required bool closeSettings}) async {
    final draftToSave = _rootDraft;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final oldRefs = widget.controller.config.customSources
          .expand((source) => source.secretHeaderRefs.values)
          .toSet();
      await widget.controller.apply(draftToSave);
      final newRefs = draftToSave.customSources
          .expand((source) => source.secretHeaderRefs.values)
          .toSet();
      for (final key in {...oldRefs, ..._createdSecrets}.difference(newRefs)) {
        try {
          await widget.controller.secrets.delete(key);
        } catch (_) {}
      }
      _createdSecrets.clear();
      if (mounted) {
        // Keep the current form, scroll and catalog ordering. Only advance its
        // committed baseline; subsequent edits remain independent drafts.
        setState(() => _rootDraft = widget.controller.config);
      }
      if (mounted && closeSettings) {
        widget.onSaved?.call();
        widget.onClose();
      }
      return true;
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = context.l10n.settingSaveFailed(
            localizeAppError(context, error),
          ),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) _close();
    },
    child: Material(
      color: Theme.of(context).colorScheme.surface,
      child: ExcludeFocus(
        excluding: _saving || _closing || _loadingDraft,
        child: AbsorbPointer(
          absorbing: _saving || _closing || _loadingDraft,
          child: Column(
            children: [
              _settingsHeader(),
              if (_showsTargetSelector)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<DisplayTarget>(
                      key: const ValueKey('display-target-selector'),
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: DisplayTarget.floating,
                          icon: _compactHeight
                              ? null
                              : const Icon(
                                  Icons.picture_in_picture_alt,
                                  size: 18,
                                ),
                          label: Text(
                            _compactHeight && !context.metrics.chinese
                                ? 'Floating'
                                : context.metrics.floating,
                          ),
                        ),
                        ButtonSegment(
                          value: DisplayTarget.taskbar,
                          icon: _compactHeight
                              ? null
                              : const Icon(Icons.dock_outlined, size: 18),
                          label: Text(context.metrics.taskbar),
                        ),
                      ],
                      selected: {_target},
                      onSelectionChanged: (values) => setState(() {
                        _target = values.single;
                        _resetCatalogOrder();
                        _assetPage = 0;
                        _assetSearch.clear();
                        _search = '';
                        if (_scrollController.hasClients) {
                          _scrollController.jumpTo(0);
                        }
                      }),
                    ),
                  ),
                ),
              if (_error != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        size: 20,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 760;
                    final narrow = constraints.maxWidth < 560;
                    final body = KeyedSubtree(
                      key: ValueKey(
                        'settings-form-${_target.name}-$_draftRevision',
                      ),
                      child: _settingsQuery.trim().isEmpty
                          ? _sectionBody()
                          : _searchResults(),
                    );
                    if (narrow && constraints.maxHeight < 200) {
                      return Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                Expanded(child: _searchField()),
                                PopupMenuButton<int>(
                                  key: const ValueKey(
                                    'compact-settings-categories',
                                  ),
                                  tooltip: context.metrics.chinese
                                      ? '设置分类'
                                      : 'Settings sections',
                                  icon: const Icon(
                                    Icons.tune_rounded,
                                    size: 20,
                                  ),
                                  initialValue: _section,
                                  onSelected: (value) => _selectSection(value),
                                  itemBuilder: (context) => [
                                    for (
                                      var i = 0;
                                      i < settingsCategories.length;
                                      i++
                                    )
                                      PopupMenuItem(
                                        value: i,
                                        child: Text(
                                          settingsCategories[i].title(
                                            context.l10n,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Expanded(child: body),
                        ],
                      );
                    }
                    if (narrow) {
                      return Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: _searchField(),
                          ),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                            child: Row(
                              children: [
                                for (
                                  var i = 0;
                                  i < settingsCategories.length;
                                  i++
                                )
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: ChoiceChip(
                                      label: Text(
                                        settingsCategories[i].title(
                                          context.l10n,
                                        ),
                                      ),
                                      selected:
                                          i == _section &&
                                          _settingsQuery.isEmpty,
                                      onSelected: (_) => _selectSection(i),
                                      showCheckmark: false,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Expanded(child: body),
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _navigationPane(extended: wide),
                        Expanded(
                          child: Column(
                            children: [
                              if (!wide)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    0,
                                    20,
                                    12,
                                  ),
                                  child: _searchField(),
                                ),
                              Expanded(child: body),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              _settingsFooter(),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _settingsHeader() => SizedBox(
    height: _compactHeight ? 40 : 56,
    child: Row(
      children: [
        const SizedBox(width: 8),
        FIconButton(
          onPressed: _saving || _pickingImage || _closing ? null : _close,
          tooltip: context.l10n.settingReturnToPanel,
          icon: const Icon(Icons.arrow_back_rounded, size: 20),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => widget.controller.host.beginDrag(),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  context.l10n.settingTitle,
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _navigationPane({required bool extended}) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: extended ? 196 : 68,
      margin: const EdgeInsets.only(left: 8, bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          if (extended) ...[_searchField(), const SizedBox(height: 16)],
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (var i = 0; i < settingsCategories.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Tooltip(
                      message: extended
                          ? ''
                          : settingsCategories[i].title(context.l10n),
                      child: Material(
                        color: i == _section && _settingsQuery.isEmpty
                            ? colors.primaryContainer
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          onTap: () => _selectSection(i),
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            height: 42,
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: extended ? 12 : 0,
                              ),
                              child: Row(
                                mainAxisAlignment: extended
                                    ? MainAxisAlignment.start
                                    : MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    settingsCategories[i].icon,
                                    size: 20,
                                    color: i == _section
                                        ? colors.onPrimaryContainer
                                        : colors.onSurfaceVariant,
                                  ),
                                  if (extended) ...[
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        settingsCategories[i].title(
                                          context.l10n,
                                        ),
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: i == _section
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                          color: i == _section
                                              ? colors.onPrimaryContainer
                                              : colors.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingsFooter() => Container(
    padding: _compactHeight
        ? const EdgeInsets.fromLTRB(12, 4, 12, 6)
        : const EdgeInsets.fromLTRB(20, 10, 20, 14),
    child: Row(
      children: [
        Icon(
          _dirty ? Icons.edit_outlined : Icons.check_circle_outline_rounded,
          size: 16,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _saving
                ? context.l10n.settingSaving
                : _dirty
                ? (context.metrics.chinese
                      ? '已改 $_changedCount 项 · 关闭时自动保存'
                      : '$_changedCount changed · saves on close')
                : context.l10n.settingSaved,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        PopupMenuButton<String>(
          key: const ValueKey('settings-more'),
          tooltip: context.metrics.chinese ? '更多' : 'More',
          icon: const Icon(Icons.more_vert_rounded, size: 18),
          onSelected: (value) {
            switch (value) {
              case 'export':
                unawaited(_exportConfig());
              case 'import':
                unawaited(_importConfig());
              default:
                unawaited(_resetEverything());
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'export',
              child: Text(
                context.metrics.chinese ? '导出配置…' : 'Export settings…',
              ),
            ),
            PopupMenuItem(
              value: 'import',
              child: Text(
                context.metrics.chinese ? '导入配置…' : 'Import settings…',
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'reset',
              child: Text(
                context.metrics.chinese ? '恢复全部默认…' : 'Reset everything…',
              ),
            ),
          ],
        ),
        const SizedBox(width: 4),
        FilledButton(
          key: const ValueKey('settings-save'),
          onPressed:
              !_dirty || _saving || _pickingImage || _closing || _loadingDraft
              ? null
              : _saveAndStay,
          child: Text(context.l10n.editSave),
        ),
      ],
    ),
  );

  /// Writes the whole config to a file the user picks. The file is the same
  /// shape as the one on disk, so it can be read back or hand-edited.
  Future<void> _exportConfig() async {
    final stamp = DateTime.now().toIso8601String().split('T').first;
    final location = await getSaveLocation(
      suggestedName: 'duomonitor-$stamp.json',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (location == null || !mounted) return;
    try {
      await File(location.path)
          .writeAsString('${encodeJson(_rootDraft.toJson())}\n');
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = context.l10n.settingSaveFailed(
            localizeAppError(context, error),
          ),
        );
      }
    }
  }

  /// Reads a config file back. Unknown keys are dropped by [AppConfig.fromJson]
  /// rather than rejecting the whole file, which is what lets an older export
  /// still restore on a newer build.
  Future<void> _importConfig() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (file == null || !mounted) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('settings file is not a JSON object');
      }
      final imported = AppConfig.fromJson(decoded);
      _commitRoot(imported);
      setState(() {
        _draftRevision++;
        _target = DisplayTarget.floating;
        _resetCatalogOrder();
        _error = null;
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = context.l10n.settingSaveFailed(
            localizeAppError(context, error),
          ),
        );
      }
    }
  }

  /// Resets the whole config. Destructive and irreversible, so it asks first -
  /// this is the one place the danger colour is allowed.
  Future<void> _resetEverything() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.metrics.chinese ? '恢复全部默认' : 'Reset everything'),
        content: Text(
          context.metrics.chinese ? '所有设置都会回到初始值，包括关注列表、数据源和窗口位置。这一步不能撤销。' : 'Every setting returns to its initial value, including the watchlist, sources and window position. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.editCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.metrics.chinese ? '恢复' : 'Reset'),
          ),
        ],
      ),
    );
    if (confirmed == true) _commitRoot(AppConfig.defaults);
  }

  Widget _searchField() => FTextField(
    controller: _settingsSearch,
    decoration: InputDecoration(
      hintText: context.l10n.settingSearch,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      prefixIcon: const Icon(Icons.search_rounded, size: 19),
      prefixIconConstraints: const BoxConstraints(minWidth: 34),
      suffixIcon: _settingsQuery.isEmpty
          ? null
          : FIconButton(
              tooltip: context.l10n.settingClearSearch,
              icon: const Icon(Icons.close_rounded, size: 17),
              onPressed: () {
                _settingsSearch.clear();
                setState(() => _settingsQuery = '');
              },
            ),
    ),
    onChanged: (value) => setState(() => _settingsQuery = value),
  );

  /// Fixed group order from the shared settings contract:
  /// general -> appearance -> app groups (at most three) -> notifications ->
  /// privacy -> advanced -> about.
  ///
  /// Groups with nothing in them are absent rather than empty. The two app
  /// groups below are the only ones this app gets to name.
  /// The target switch only means something in the groups whose settings are
  /// per-display. General, privacy and about are shared, so showing the switch
  /// there would imply they follow it too - which is exactly the confusion that
  /// made the page feel arbitrary.
  bool get _showsTargetSelector => _section == 1 || _section == 2;

  Widget _sectionBody() => switch (_section) {
    0 => _general(),
    1 => _appearanceDeclared(),
    2 => _display(),
    3 => _privacy(),
    _ => _about(),
  };

  /// Settings that change both displays, so they sit outside the target switch:
  /// language, whether the panel exists at all, and how it pins or hides.
  ///
  /// These used to form a "window" group of their own. That name sat too close
  /// to "display" to be useful, so the group is gone and its contents live here.
  Widget _general() => _page([
    _intro(
      context.metrics.chinese ? '通用' : 'General',
      context.metrics.chinese
          ? '语言和窗口行为，两个显示位置共用。'
          : 'Language and window behaviour, shared by both displays.',
    ),
    _scopeCaption(context.l10n.settingScopeShared),
    _card(
      SettingRow(
        title: context.l10n.settingLanguage,
        description: context.metrics.chinese
            ? '两个显示位置共用同一个语言。'
            : 'Both displays share one language.',
        controlWidth: 164,
        control: FDropdown<String>(
          key: ValueKey('language-${_draft.language}'),
          initialValue: _draft.language,
          isExpanded: true,
          decoration: const InputDecoration(isDense: true),
          items: [
            FDropdownItem(
              value: 'system',
              child: Text(context.metrics.chinese ? '跟随系统' : 'System'),
            ),
            FDropdownItem(value: 'zh', child: const Text('简体中文')),
            FDropdownItem(value: 'en', child: const Text('English')),
          ],
          onChanged: (value) {
            if (value != null) {
              _commit(_draft.copyWith(language: value));
            }
          },
        ),
      ),
    ),
    const SizedBox(height: 18),
    ..._windowChildren(),
  ], includeStorage: false);

  /// App group: what is shown and how. The watchlist, its sources, the rows and
  /// the units all answer the same question - "what appears on the panel" - so
  /// they are one group. Arrangement lives in the appearance group instead.
  /// The taskbar is the second display target, so its own editor belongs here.
  Widget _display() => _page([
    if (_target == DisplayTarget.taskbar) ...[
      _scopeCaption(context.l10n.settingScopeTaskbar),
      TaskbarSettingsView(
        config: _draft,
        snapshot: widget.controller.metrics.snapshot,
        quotes: widget.controller.displayQuotes,
        rates: widget.controller.data.exchangeRates,
        priceTicks: _priceTicks,
        status: widget.controller.taskbar.state,
        onChanged: _commit,
      ),
      const SizedBox(height: 24),
    ],
    ..._assetsChildren(),
    const SizedBox(height: 24),
    ..._sourcesChildren(),
    const SizedBox(height: 24),
    ..._rowsChildren(),
    const SizedBox(height: 24),
    ..._unitsChildren(),
    const SizedBox(height: 24),
    ..._metricsChildren(),
  ], includeStorage: false);

  /// Storage used to be appended to every section. It is one thing, in one
  /// place, under the group the contract reserves for it.
  Widget _privacy() => _page([
    _intro(
      context.l10n.settingStorage,
      context.metrics.chinese ? '设置文件、行情目录和旧版导入都在这里。' : 'The settings file, the market catalogue and the legacy import all live here.',
    ),
    _anchor('storage', _storage()),
  ], includeStorage: false);

  Widget _about() => _page([
    _intro(
      context.metrics.chinese ? '关于' : 'About',
      context.metrics.chinese ? 'DuoMonitor 把行情、接口数据和系统指标放在一块面板上。' : 'DuoMonitor keeps market data, API values and system metrics on one panel.',
    ),
    _card(
      Column(
        children: [
          SettingRow(
            title: context.metrics.chinese ? '版本' : 'Version',
            controlWidth: 120,
            control: Text(
              '1.6.0',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(height: 1),
          SettingRow(
            title: context.metrics.chinese ? '许可' : 'Licence',
            controlWidth: 120,
            control: Text(
              'MIT',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(height: 1),
          SettingRow(
            title: context.metrics.chinese ? '源码' : 'Source',
            controlWidth: 220,
            control: Text(
              'github.com/Jaron-admin/DuoMonitor',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    ),
  ], includeStorage: false);

  List<Widget> _unitsChildren() => [
    _intro(
      context.l10n.settingUnitsTitle,
      context.l10n.settingUnitsDescription,
    ),
    _scopeCaption(_surfaceScope),
    _anchor('units', _unitOptions()),
  ];

  List<Widget> _metricsChildren() => [
    _anchor(
      'metrics',
      SystemMonitorSettingsView(
        config: _draft,
        snapshot: widget.controller.metrics.snapshot,
        scopeCaption: _surfaceScope,
        onChanged: _commit,
      ),
    ),
  ];

  String get _surfaceScope => _target == DisplayTarget.taskbar
      ? context.l10n.settingScopeTaskbar
      : context.l10n.settingScopePanel;

  Map<String, PriceTick> get _priceTicks => {
    for (final quote in widget.controller.displayQuotes.values)
      quote.assetId: widget.controller.priceTickFor(quote.assetId),
  };

  Widget _scopeCaption(String text) => Padding(
    padding: const EdgeInsets.only(top: 2, bottom: 12),
    child: Text(
      text,
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  void _selectSection(int section, {String? anchor}) {
    FocusManager.instance.primaryFocus?.unfocus();
    _settingsSearch.clear();
    setState(() {
      if (section == 0 && (_section != 0 || _settingsQuery.isNotEmpty)) {
        _resetCatalogOrder();
        _assetPage = 0;
      }
      _section = section;
      _settingsQuery = '';
      _highlightedAnchor = anchor;
      if (anchor == 'storage') _storageExpanded = true;
    });
    if (section == 0) _loadCatalog();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
      final target = anchor == null ? null : _anchors[anchor]?.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(target, alignment: 0.08);
      }
    });
  }

  Widget _searchResults() {
    final matches = settingsLocations
        .where((entry) => entry.matches(_settingsQuery))
        .toList();
    return _page([
      _intro(
        context.l10n.settingSearch,
        context.l10n.settingSearchCount(matches.length),
      ),
      if (matches.isEmpty)
        Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text(context.l10n.settingNoSearchResults),
        ),
      for (final entry in matches)
        _card(
          FListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(settingsCategories[entry.section].icon, size: 20),
            title: Text(entry.title(context.l10n)),
            subtitle: Text(
              settingsCategories[entry.section].title(context.l10n),
            ),
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: () => _selectSection(entry.section, anchor: entry.anchor),
          ),
        ),
    ], includeStorage: false);
  }

  Widget _anchor(String id, Widget child) => Container(
    key: _anchors.putIfAbsent(id, GlobalKey.new),
    decoration: BoxDecoration(
      border: _highlightedAnchor == id
          ? Border(
              left: BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 3,
              ),
            )
          : null,
    ),
    child: child,
  );

  Widget _page(List<Widget> children, {bool includeStorage = true}) =>
      Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        interactive: true,
        child: SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...children,
                  if (includeStorage) ...[
                    const SizedBox(height: 18),
                    _anchor('storage', _storage()),
                  ],
                ],
              ),
            ),
          ),
        ),
      );

  Widget _storage() => FExpansionTile(
    key: ValueKey('storage-$_section-$_storageExpanded'),
    initiallyExpanded: _storageExpanded,
    onExpansionChanged: (value) => _storageExpanded = value,
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: 8),
    title: Text(context.l10n.settingStorage, style: TextStyle(fontSize: 12)),
    children: [
      _scopeCaption(context.l10n.settingScopeShared),
      KeyedSubtree(
        key: ValueKey(
          'storage-mode-$_storageRevision-${widget.controller.storageMode.name}',
        ),
        child: FDropdown<DataStorageMode>(
          key: const ValueKey('data-storage-mode'),
          initialValue: widget.controller.storageMode,
          decoration: InputDecoration(
            labelText: context.l10n.settingStorageMode,
          ),
          items: [
            FDropdownItem(
              value: DataStorageMode.portable,
              child: Text(context.l10n.settingStoragePortable),
            ),
            FDropdownItem(
              value: DataStorageMode.system,
              child: Text(context.l10n.settingStorageSystem),
            ),
          ],
          onChanged: (value) {
            if (value != null) unawaited(_changeStorage(value));
          },
        ),
      ),
      const SizedBox(height: 8),
      Text(
        context.l10n.settingStorageModeHint,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: FTextButton.icon(
          onPressed: _saving ? null : _importLegacy,
          icon: const Icon(Icons.file_download_outlined, size: 17),
          label: Text(context.l10n.settingImportLegacy),
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: SelectableText(
          context.l10n.settingSettingsFile(widget.controller.store.configPath),
          style: const TextStyle(fontSize: 11),
        ),
      ),
    ],
  );

  Future<void> _changeStorage(DataStorageMode mode) async {
    if (_saving || _storageChanging || mode == widget.controller.storageMode) {
      return;
    }
    _storageChanging = true;
    final migrate = await showDialog<bool>(
      context: context,
      builder: (context) => FAlertDialog(
        title: Text(context.l10n.settingStorageMigrateTitle),
        content: Text(context.l10n.settingStorageMigrateBody),
        actions: [
          FTextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.settingCancel),
          ),
          FTextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.settingStorageSwitchOnly),
          ),
          FFilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.settingStorageMigrate),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (migrate == null) {
      setState(() {
        _storageRevision++;
        _storageChanging = false;
      });
      return;
    }
    // Preserve pending edits in the current store before selecting another one.
    if (_dirty && !await _save(closeSettings: false)) {
      if (mounted) {
        setState(() {
          _storageRevision++;
          _storageChanging = false;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _storageChanging = true;
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.switchStorage(mode, migrate: migrate);
      if (mounted) {
        setState(() {
          _rootDraft = widget.controller.config;
          _draftRevision++;
          _storageRevision++;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _storageRevision++;
        _error = context.l10n.settingStorageSwitchFailed;
      });
    } finally {
      if (mounted) {
        setState(() {
          _storageChanging = false;
          _saving = false;
        });
      }
    }
  }

  Widget _intro(String title, String description) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 5),
        Text(
          description,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
            height: 1.4,
          ),
        ),
      ],
    ),
  );

  Widget _card(Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: child,
      ),
    ),
  );
  List<Widget> _assetsChildren() {
    final directory = widget.controller.catalog;
    final catalog = _catalogSnapshot;
    final terms = _search.toLowerCase().trim().split(RegExp(r'\s+'));
    final filtered = catalog.values
        .where(
          (asset) =>
              (_kind == 'all' ||
                  (_kind == 'crypto'
                      ? asset.kind == MarketKind.crypto
                      : asset.kind == MarketKind.equity)) &&
              (_provider == 'all' || asset.provider == _provider) &&
              terms.every(
                '${asset.name} ${localizedAssetName(asset, context.l10n)} ${asset.symbol} ${asset.symbol.replaceAll('-', ' ')} ${asset.provider} ${asset.currency}'
                    .toLowerCase()
                    .contains,
              ),
        )
        .toList();
    const pageSize = 100;
    final pageCount = ((filtered.length + pageSize - 1) ~/ pageSize).clamp(
      1,
      999999,
    );
    final currentPage = _assetPage.clamp(0, pageCount - 1);
    final page = filtered.skip(currentPage * pageSize).take(pageSize);
    return [
      _intro(
        context.l10n.settingWatchlist,
        context.l10n.settingWatchlistDescription,
      ),
      _scopeCaption(_surfaceScope),
      _anchor('asset-order', _watchlistOrder()),
      const SizedBox(height: 18),
      _anchor(
        'assets',
        Text(
          context.l10n.settingAddAsset,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      const SizedBox(height: 10),
      FTextField(
        controller: _assetSearch,
        decoration: InputDecoration(
          labelText: context.l10n.settingSearchAsset,
          prefixIcon: Icon(Icons.search),
        ),
        onChanged: (value) => setState(() {
          _search = value;
          _assetPage = 0;
        }),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final entry in {
            'all': context.l10n.settingAll,
            'crypto': context.l10n.settingCrypto,
            'equity': context.l10n.settingStocks,
          }.entries)
            FChoiceChip(
              label: Text(entry.value),
              selected: _kind == entry.key,
              onSelected: (_) => setState(() {
                _kind = entry.key;
                _provider = 'all';
                _assetPage = 0;
              }),
            ),
          SizedBox(
            width: 164,
            child: FDropdown<String>(
              key: ValueKey(_provider),
              initialValue: _provider,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: context.l10n.settingProvider,
              ),
              items: [
                FDropdownItem(
                  value: 'all',
                  child: Text(context.l10n.settingAllProviders),
                ),
                FDropdownItem(value: 'OKX', child: Text('OKX')),
                FDropdownItem(value: 'BINANCE', child: Text('Binance')),
                FDropdownItem(value: 'KUCOIN', child: Text('KuCoin')),
                FDropdownItem(
                  value: 'YAHOO',
                  child: Text(context.l10n.settingYahoo),
                ),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _provider = value;
                  if (value != 'all') {
                    _kind = value == 'YAHOO' ? 'equity' : 'crypto';
                  }
                  _assetPage = 0;
                });
              },
            ),
          ),
          FButton.icon(
            onPressed: _addAsset,
            icon: const Icon(Icons.add),
            label: Text(context.l10n.settingAddSymbol),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            context.l10n.settingCatalogCounts(
              _draft.selectedAssetIds.length,
              catalog.length,
              filtered.length,
            ),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          FTextButton.icon(
            onPressed: directory.loading
                ? null
                : () => _loadCatalog(force: true),
            icon: directory.loading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, size: 16),
            label: Text(
              directory.loading
                  ? context.l10n.settingUpdatingCatalog
                  : context.l10n.settingRefreshCatalog,
            ),
          ),
        ],
      ),
      if (directory.errors.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            context.l10n.settingCatalogUnavailable(
              directory.errors.keys.join(', '),
            ),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ),
      for (final asset in page)
        Padding(
          key: _catalogRowKeys.putIfAbsent(asset.id, GlobalKey.new),
          padding: const EdgeInsets.only(bottom: 6),
          child: Card(
            margin: EdgeInsets.zero,
            child: FCheckboxListTile(
              key: ValueKey('catalog-${asset.id}'),
              dense: true,
              visualDensity: const VisualDensity(vertical: -1),
              value: _draft.selectedAssetIds.contains(asset.id),
              title: Text(
                localizedAssetName(asset, context.l10n),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${asset.symbol}  ·  ${asset.provider}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onChanged: (value) =>
                  _toggleAsset(asset, value == true, keepCatalogPosition: true),
            ),
          ),
        ),
      if (filtered.isEmpty)
        Padding(
          padding: EdgeInsets.all(24),
          child: Text(context.l10n.settingSymbolNotFound),
        ),
      if (pageCount > 1)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FIconButton(
                tooltip: context.l10n.settingPreviousPage,
                onPressed: currentPage == 0
                    ? null
                    : () => _changeAssetPage(currentPage - 1),
                icon: const Icon(Icons.chevron_left),
              ),
              Flexible(
                child: Text(
                  context.l10n.settingPageCount(
                    currentPage + 1,
                    pageCount,
                    pageSize,
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              FIconButton(
                tooltip: context.l10n.settingNextPage,
                onPressed: currentPage == pageCount - 1
                    ? null
                    : () => _changeAssetPage(currentPage + 1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
    ];
  }

  Widget _watchlistOrder() {
    final assets = _draft.assets;
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              context.l10n.settingWatchlistCount(assets.length),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (assets.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(context.l10n.settingAddFromCatalog),
            )
          else
            SizedBox(
              height: (assets.length * 60.0).clamp(60.0, 300.0),
              child: Scrollbar(
                controller: _watchlistScrollController,
                thumbVisibility: true,
                child: ReorderableListView.builder(
                  scrollController: _watchlistScrollController,
                  primary: false,
                  itemExtent: 60,
                  buildDefaultDragHandles: false,
                  itemCount: assets.length,
                  onReorderItem: _reorderAsset,
                  proxyDecorator: (child, index, animation) => Material(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    elevation: 4,
                    borderRadius: BorderRadius.circular(4),
                    child: child,
                  ),
                  itemBuilder: (context, i) {
                    final asset = assets[i];
                    return Container(
                      key: ValueKey('watch-order-${asset.id}'),
                      decoration: BoxDecoration(
                        border: i == assets.length - 1
                            ? null
                            : Border(
                                bottom: BorderSide(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant,
                                ),
                              ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            ReorderableDragStartListener(
                              index: i,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.grab,
                                child: Tooltip(
                                  message: context.l10n.settingDragToReorder,
                                  child: Semantics(
                                    label: context.l10n.settingDragAsset(
                                      localizedAssetName(asset, context.l10n),
                                    ),
                                    child: const Padding(
                                      padding: EdgeInsets.all(8),
                                      child: Icon(
                                        Icons.drag_indicator_rounded,
                                        size: 16,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    localizedAssetName(asset, context.l10n),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    '${asset.symbol} · ${asset.provider}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            FIconButton(
                              tooltip: context.l10n.settingMoveAssetUp(
                                localizedAssetName(asset, context.l10n),
                              ),
                              icon: const Icon(
                                Icons.keyboard_arrow_up_rounded,
                                size: 14,
                              ),
                              onPressed: i == 0
                                  ? null
                                  : () => _moveAsset(i, -1),
                            ),
                            FIconButton(
                              tooltip: context.l10n.settingMoveAssetDown(
                                localizedAssetName(asset, context.l10n),
                              ),
                              icon: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 14,
                              ),
                              onPressed: i == assets.length - 1
                                  ? null
                                  : () => _moveAsset(i, 1),
                            ),
                            FIconButton(
                              tooltip: context.l10n.settingUnfollowAsset(
                                localizedAssetName(asset, context.l10n),
                              ),
                              icon: const Icon(Icons.close_rounded, size: 12),
                              onPressed: () => _toggleAsset(asset, false),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _reorderAsset(int oldIndex, int newIndex) {
    final visible = _draft.assets.map((asset) => asset.id).toList();
    if (newIndex == oldIndex) return;
    final moved = visible.removeAt(oldIndex);
    visible.insert(newIndex, moved);
    // Keep any temporarily unavailable IDs in their slots.
    final visibleIds = visible.toSet();
    var index = 0;
    final ordered = [
      for (final id in _draft.selectedAssetIds)
        visibleIds.contains(id) ? visible[index++] : id,
    ];
    _commit(_draft.copyWith(selectedAssetIds: ordered));
  }

  Map<String, Asset> _availableCatalog() => {
    for (final asset in [
      ...widget.controller.catalog.assets,
      ...Asset.popular,
      ..._draft.customAssets,
    ])
      asset.id: asset,
  };

  void _resetCatalogOrder() {
    final selectedOrder = {
      for (var i = 0; i < _draft.selectedAssetIds.length; i++)
        _draft.selectedAssetIds[i]: i,
    };
    final popularOrder = {
      for (var i = 0; i < Asset.popular.length; i++) Asset.popular[i].id: i,
    };
    int rank(Asset asset) =>
        selectedOrder[asset.id] ??
        (selectedOrder.length +
            (popularOrder[asset.id] ?? Asset.popular.length));
    final assets = _availableCatalog().values.toList()
      ..sort((a, b) {
        final priority = rank(a).compareTo(rank(b));
        return priority == 0 ? a.id.compareTo(b.id) : priority;
      });
    _catalogSnapshot
      ..clear()
      ..addEntries(assets.map((asset) => MapEntry(asset.id, asset)));
  }

  void _appendCatalogUpdates() {
    final assets = _availableCatalog().values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    // Updating an existing map entry preserves its position. New exchange
    // results append, so asynchronous directory loads cannot move visible rows.
    for (final asset in assets) {
      _catalogSnapshot[asset.id] = asset;
    }
  }

  void _catalogChanged() {
    if (mounted) setState(_appendCatalogUpdates);
  }

  void _loadCatalog({bool force = false}) {
    if (_catalogRequested && !force) return;
    if (force) {
      setState(() {
        _resetCatalogOrder();
        _assetPage = 0;
      });
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    }
    _catalogRequested = true;
    unawaited(
      widget.controller.catalog.refresh(force: force).catchError((
        Object error,
      ) {
        if (mounted) setState(() => _error = context.l10n.settingCatalogFailed);
      }),
    );
  }

  double? _catalogRowTop(String id) {
    final row = _catalogRowKeys[id]?.currentContext?.findRenderObject();
    return row is RenderBox && row.attached && row.hasSize
        ? row.localToGlobal(Offset.zero).dy
        : null;
  }

  void _toggleAsset(
    Asset asset,
    bool selected, {
    bool keepCatalogPosition = false,
  }) {
    final previousTop = keepCatalogPosition ? _catalogRowTop(asset.id) : null;
    final previousOffset = _scrollController.hasClients
        ? _scrollController.offset
        : null;
    _commit(
      _draft.copyWith(
        customAssets: selected
            ? [
                ..._draft.customAssets.where((item) => item.id != asset.id),
                asset,
              ]
            : _draft.customAssets,
        selectedAssetIds: selected
            ? {..._draft.selectedAssetIds, asset.id}.toList()
            : _draft.selectedAssetIds.where((id) => id != asset.id).toList(),
      ),
    );
    if (previousTop != null && previousOffset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        // The watchlist above the catalog can grow or shrink. Keep the clicked
        // row at the same screen position, without overriding a later scroll.
        if ((_scrollController.offset - previousOffset).abs() > 0.5) return;
        final nextTop = _catalogRowTop(asset.id);
        if (nextTop == null) return;
        final position = _scrollController.position;
        final offset = (previousOffset + nextTop - previousTop).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if ((offset - previousOffset).abs() > 0.5) {
          _scrollController.jumpTo(offset);
        }
      });
    }
  }

  void _changeAssetPage(int page) {
    setState(() => _assetPage = page);
    _scrollController.jumpTo(0);
  }

  void _moveAsset(int index, int direction) {
    final ids = [..._draft.selectedAssetIds];
    final id = _draft.assets[index].id;
    final actual = ids.indexOf(id);
    final otherId = _draft.assets[index + direction].id;
    final other = ids.indexOf(otherId);
    ids[actual] = otherId;
    ids[other] = id;
    _commit(_draft.copyWith(selectedAssetIds: ids));
  }

  Future<void> _addAsset() async {
    final asset = await showDialog<Asset>(
      context: context,
      builder: (context) => const _AssetDialog(),
    );
    if (asset == null || !mounted) return;
    _appendCatalogUpdates();
    _commit(
      _draft.copyWith(
        customAssets: [
          ..._draft.customAssets.where((item) => item.id != asset.id),
          asset,
        ],
        selectedAssetIds: {..._draft.selectedAssetIds, asset.id}.toList(),
      ),
    );
  }

  Future<void> _importLegacy() async {
    final input = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (context) => FAlertDialog(
        title: Text(context.l10n.settingImportLegacy),
        content: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(context.l10n.settingImportDescription),
              const SizedBox(height: 16),
              FTextField(
                controller: input,
                decoration: InputDecoration(
                  labelText: context.l10n.settingLegacyPath,
                  hintText: context.l10n.settingLegacyPathHint,
                ),
              ),
            ],
          ),
        ),
        actions: [
          FTextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.settingCancel),
          ),
          FFilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: Text(context.l10n.settingRead),
          ),
        ],
      ),
    );
    input.dispose();
    if (path == null || !mounted) return;
    setState(() => _loadingDraft = true);
    try {
      final imported = await widget.controller.store.importLegacy(path);
      if (mounted) {
        setState(() {
          _rootDraft = imported;
          _draftRevision++;
          _target = DisplayTarget.floating;
          _resetCatalogOrder();
          _assetPage = 0;
        });
        widget.controller.previewAppearance(_rootDraft);
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = context.l10n.settingImportFailed(
            localizeAppError(context, error),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingDraft = false);
    }
  }

  List<Widget> _sourcesChildren() => [
    _scopeCaption(context.l10n.settingScopeShared),
    _anchor(
      'sources',
      _intro(
        context.l10n.settingCustomContent,
        context.l10n.settingCustomDescription,
      ),
    ),
    FFilledButton.icon(
      onPressed: () => _editSource(null),
      icon: const Icon(Icons.add),
      label: Text(context.l10n.settingAddApi),
    ),
    const SizedBox(height: 20),
    if (_draft.customSources.isEmpty)
      _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.settingThreeSteps,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(context.l10n.settingApiSteps, style: TextStyle(height: 1.8)),
            const SizedBox(height: 12),
            Text(
              context.l10n.settingApiSecurity,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    for (final source in _draft.customSources)
      _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    source.name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                FIconButton(
                  onPressed: () => _editSource(source),
                  tooltip: context.l10n.settingEdit,
                  icon: const Icon(Icons.edit_outlined),
                ),
                FIconButton(
                  onPressed: () => _removeSource(source),
                  tooltip: context.l10n.settingRemove,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            Text(
              source.url,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final field in source.fields)
                  FilterChip(
                    selected: _draft.selectedCustomFieldIds.contains(
                      customFieldKey(source.id, field.id),
                    ),
                    onSelected: (selected) {
                      final key = customFieldKey(source.id, field.id);
                      _commit(
                        _draft.copyWith(
                          selectedCustomFieldIds: [
                            ..._draft.selectedCustomFieldIds.where(
                              (value) => value != key,
                            ),
                            if (selected) key,
                          ],
                        ),
                      );
                    },
                    label: Text(
                      '${field.label}${field.unit.isEmpty ? '' : ' · ${field.unit}'}',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.settingSourceSummary(
                source.enabled
                    ? context.l10n.settingEnabled
                    : context.l10n.settingDisabled,
                source.refreshSeconds,
                source.fields.length,
              ),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
  ];

  Future<void> _editSource(CustomApiSource? source) async {
    final result = await showDialog<SourceEditResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          SourceEditor(controller: widget.controller, source: source),
    );
    if (result == null || !mounted) return;
    _createdSecrets.addAll(result.createdSecretKeys);
    final removed =
        source?.fields
            .where(
              (field) =>
                  !result.source.fields.any((next) => next.id == field.id),
            )
            .expand(
              (field) => [
                customFieldKey(source.id, field.id),
                customFieldKey(source.id, '${field.id}.unit'),
              ],
            )
            .toSet() ??
        <String>{};
    if (DisplayDependencies.forConfig(
      _rootDraft,
      includeDisabled: true,
    ).customFieldIds.any(removed.contains)) {
      setState(() => _error = context.metrics.removeSourceBody);
      return;
    }
    _commit(
      _draft.copyWith(
        customSources: [
          ..._draft.customSources.where((item) => item.id != result.source.id),
          result.source,
        ],
        selectedCustomFieldIds: source == null
            ? [
                ..._draft.selectedCustomFieldIds,
                for (final field in result.source.fields)
                  customFieldKey(result.source.id, field.id),
              ]
            : _draft.selectedCustomFieldIds,
      ),
    );
  }

  void _removeSource(CustomApiSource source) {
    if (DisplayDependencies.forConfig(
      _rootDraft,
      includeDisabled: true,
    ).customSourceIds.contains(source.id)) {
      setState(() => _error = context.metrics.removeSourceBody);
      return;
    }
    _commit(
      _draft.copyWith(
        customSources: _draft.customSources
            .where((item) => item.id != source.id)
            .toList(),
      ),
    );
  }

  /// What is shown, in what order. Arrangement moved to the appearance group:
  /// columns and gaps change how the same content looks, not what it is.
  List<Widget> _rowsChildren() => [
    _displayOrder(),
    _card(
      PriceFormatSettings(
        config: _draft,
        onChanged: _commit,
        quotes: widget.controller.displayQuotes,
        rates: widget.controller.data.exchangeRates,
      ),
    ),
    _anchor(
      'default-rows',
      _card(
        FSwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(context.l10n.settingDefaultRows),
          subtitle: Text(context.l10n.settingDefaultRowsDescription),
          value: _draft.showDefaultRows,
          onChanged: (value) =>
              _commit(_draft.copyWith(showDefaultRows: value)),
        ),
      ),
    ),
    _anchor(
      'custom-rows',
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          FFilledButton.icon(
            onPressed: () => _editRow(null),
            icon: const Icon(Icons.add),
            label: Text(context.l10n.settingAddRow),
          ),
          FButton.icon(
            onPressed: _addTemplate,
            icon: const Icon(Icons.auto_awesome_outlined),
            label: Text(context.l10n.settingAddTemplate),
          ),
        ],
      ),
    ),
    const SizedBox(height: 20),
    if (_draft.showDefaultRows)
      _card(
        Row(
          children: [
            Icon(
              Icons.check_circle_outline,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(context.l10n.settingDefaultRowsKept)),
          ],
        ),
      ),
    for (var i = 0; i < _draft.displayRows.length; i++)
      _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.settingRowNumber(i + 1),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                FIconButton(
                  tooltip: context.l10n.settingMoveUp,
                  onPressed: i == 0 ? null : () => _moveRow(i, -1),
                  icon: const Icon(Icons.arrow_upward, size: 18),
                ),
                FIconButton(
                  tooltip: context.l10n.settingMoveDown,
                  onPressed: i == _draft.displayRows.length - 1
                      ? null
                      : () => _moveRow(i, 1),
                  icon: const Icon(Icons.arrow_downward, size: 18),
                ),
                FIconButton(
                  tooltip: context.l10n.settingEdit,
                  onPressed: () => _editRow(_draft.displayRows[i]),
                  icon: const Icon(Icons.edit_outlined),
                ),
                FIconButton(
                  tooltip: context.l10n.settingDelete,
                  onPressed: () => _commit(
                    _draft.copyWith(
                      displayRows: _draft.displayRows
                          .where((row) => row.id != _draft.displayRows[i].id)
                          .toList(),
                    ),
                  ),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final segment in _draft.displayRows[i].segments)
                  _SettingTag(
                    avatar: Icon(
                      segment.isField ? Icons.data_object : Icons.text_fields,
                      size: 16,
                    ),
                    label: Text(
                      segment.isField
                          ? fieldLabel(segment, _draft, context.l10n)
                          : segment.text,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(10),
              ),
              child: DisplayRowView(
                row: _draft.displayRows[i],
                config: _draft,
                quotes: widget.controller.displayQuotes,
                rates: widget.controller.data.exchangeRates,
                priceTicks: _priceTicks,
                showFreshness: false,
              ),
            ),
          ],
        ),
      ),
  ];

  void _moveRow(int index, int direction) {
    final rows = [..._draft.displayRows];
    final row = rows.removeAt(index);
    rows.insert(index + direction, row);
    _commit(_draft.copyWith(displayRows: rows));
  }

  Widget _displayOrder() {
    final items = buildDisplayTexts(
      _draft,
      widget.controller.displayQuotes,
      widget.controller.metrics.snapshot,
      rates: widget.controller.data.exchangeRates,
    );
    void move(int oldIndex, int newIndex) {
      final order = items.map((item) => item.id).toList();
      order.insert(newIndex, order.removeAt(oldIndex));
      _commit(_draft.copyWith(displayOrder: order));
    }

    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.settingCatalogOrder,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: items.length,
            onReorderItem: move,
            itemBuilder: (context, index) => Row(
              key: ValueKey('display-order-${items[index].id}'),
              children: [
                ReorderableDragStartListener(
                  index: index,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.drag_indicator, size: 18),
                  ),
                ),
                Expanded(
                  child: Text(
                    items[index].text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: context.metrics.up,
                  onPressed: index == 0 ? null : () => move(index, index - 1),
                  icon: const Icon(Icons.arrow_upward, size: 17),
                ),
                IconButton(
                  tooltip: context.metrics.down,
                  onPressed: index == items.length - 1
                      ? null
                      : () => move(index, index + 1),
                  icon: const Icon(Icons.arrow_downward, size: 17),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editRow(DisplayRow? row) async {
    final result = await showDialog<DisplayRow>(
      context: context,
      builder: (context) => RowEditor(
        config: _draft,
        quotes: widget.controller.displayQuotes,
        rates: widget.controller.data.exchangeRates,
        row: row,
      ),
    );
    if (result == null || !mounted) return;
    final rows = [..._draft.displayRows];
    final index = rows.indexWhere((item) => item.id == result.id);
    if (index < 0) {
      rows.add(result);
    } else {
      rows[index] = result;
    }
    _commit(_draft.copyWith(displayRows: rows));
  }

  Future<void> _addTemplate() async {
    final result = await showTemplatePicker(context, config: _draft);
    if (result != null && mounted) _commit(result);
  }

  /// Appearance section, rendered from the declared catalog.
  ///
  /// Everything here is one declaration per setting; the three panels that are
  /// genuinely custom stay widgets and are plugged in as blocks.
  Widget _appearanceDeclared() {
    final catalog = buildAppearanceCatalog(
      context.l10n,
      floating: _target == DisplayTarget.floating,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: SizedBox(
            width: double.infinity,
            height: double.infinity,
            child: TiSettingsView(
              catalog: catalog,
              config: _draft,
              onChanged: _commit,
              // the page header already searches the whole settings tree
              showSearch: false,
              // let the page-wide search scroll to a row inside this section
              anchorKeys: _anchors,
              onPickFont: (spec, current) =>
                  _chooseFont(spec.key == 'appearance.numberFontFamily'),
              blockBuilders: {
                'appearance.theme-picker': (
                  context,
                  block,
                  config,
                  onChanged,
                ) => SettingsThemePicker(config: config, onChanged: onChanged),
                'appearance.layout': (context, block, config, onChanged) =>
                    PanelLayoutSettings(
                      config: config,
                      target: _target,
                      onChanged: onChanged,
                    ),
                'appearance.price-colors': (
                  context,
                  block,
                  config,
                  onChanged,
                ) => PriceColorSettings(config: config, onChanged: onChanged),
                'appearance.font-preview': (
                  context,
                  block,
                  config,
                  onChanged,
                ) => _fontPreview(config),
                'appearance.header': (context, block, config, onChanged) =>
                    _headerOptions(),
              },
            ),
          ),
        ),
      ),
    );
  }

  /// The font specimen shown under the font pickers.
  Widget _fontPreview(AppConfig config) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).scaffoldBackgroundColor,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.settingFontPreview,
          style: TextStyle(
            fontFamily: SystemFonts.family(config.fontFamily),
            fontSize: config.fontSize,
          ),
        ),
        SizedBox(height: config.rowSpacing.clamp(4, 12)),
        Text(
          'AaBb · BTC / USDT',
          style: TextStyle(
            fontFamily: SystemFonts.family(config.fontFamily),
            fontSize: config.fontSize,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '83,342.30  +0.37%  0123456789',
          style: TextStyle(
            fontFamily: SystemFonts.family(config.numberFontFamily),
            fontFeatures: const [FontFeature.tabularFigures()],
            fontSize: config.fontSize,
          ),
        ),
      ],
    ),
  );

  /// Window behaviour: whether the panel exists, whether it stays on top, and
  /// how it hides. All three answer "how does the window exist", so they moved
  /// into the general group when the window group was retired.
  List<Widget> _windowChildren() => [
    _card(
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(context.metrics.showFloating),
        value: _rootDraft.floatingEnabled,
        onChanged: (value) =>
            _commitRoot(_rootDraft.copyWith(floatingEnabled: value)),
      ),
    ),
    _anchor(
      'window',
      _card(
        Column(
          children: [
            SettingRow(
              title: context.l10n.settingAlwaysOnTop,
              controlWidth: 52,
              control: FSwitch(
                value: _draft.alwaysOnTop,
                onChanged: (value) =>
                    _commit(_draft.copyWith(alwaysOnTop: value)),
              ),
            ),
          ],
        ),
      ),
    ),
    _anchor(
      'tray',
      _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SettingRow(
              title: context.l10n.settingHidePanel,
              description: context.l10n.settingHideDescription,
              controlWidth: 28,
              control: Icon(Icons.touch_app_outlined, size: 20),
            ),
            Divider(height: 1),
            SettingRow(
              title: context.l10n.settingRestorePanel,
              description: context.l10n.settingRestoreDescription,
              controlWidth: 28,
              control: Icon(Icons.open_in_new_rounded, size: 20),
            ),
          ],
        ),
      ),
    ),
    const SizedBox(height: 18),
  ];
  Map<String, String> get _headerIcons => {
    'chart': context.l10n.settingIconChart,
    'bitcoin': context.l10n.settingIconBitcoin,
    'star': context.l10n.settingIconStar,
    'bolt': context.l10n.settingIconBolt,
    'heart': context.l10n.settingIconHeart,
  };

  IconData? _headerIconData(String id) => switch (id) {
    'chart' => Icons.show_chart_rounded,
    'bitcoin' => Icons.currency_bitcoin,
    'star' => Icons.star_rounded,
    'bolt' => Icons.bolt_rounded,
    'heart' => Icons.favorite_rounded,
    _ => null,
  };

  Widget _headerIconPreview({double size = 24}) {
    final icon = _headerIconData(_draft.headerIcon);
    final fallback = icon == null
        ? Text(_draft.headerIcon, maxLines: 1, style: TextStyle(fontSize: size))
        : Icon(icon, size: size, color: Theme.of(context).colorScheme.primary);
    return SizedBox(
      width: size + 6,
      height: size + 6,
      child: _draft.headerImagePath.isEmpty
          ? FittedBox(child: fallback)
          : Image.file(
              File(
                widget.controller.store.resourcePath(_draft.headerImagePath) ??
                    '',
              ),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }

  Widget _headerOptions() => _card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              _headerIconPreview(),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _draft.headerName.isEmpty
                      ? context.l10n.settingTitlePreview
                      : _draft.headerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                context.l10n.settingIconPreview,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        SettingRow(
          title: context.l10n.settingShowTitle,
          controlWidth: 52,
          control: FSwitch(
            value: _draft.showHeaderName,
            onChanged: (value) =>
                _commit(_draft.copyWith(showHeaderName: value)),
          ),
        ),
        SettingRow(
          title: context.l10n.settingTitleName,
          controlWidth: 220,
          control: FTextFormField(
            key: const ValueKey('header-name'),
            initialValue: _draft.headerName,
            maxLength: 80,
            decoration: const InputDecoration(isDense: true, counterText: ''),
            onChanged: (value) => _commit(_draft.copyWith(headerName: value)),
          ),
        ),
        const Divider(height: 1),
        SettingRow(
          title: context.l10n.settingShowIcon,
          controlWidth: 52,
          control: FSwitch(
            value: _draft.showHeaderIcon,
            onChanged: (value) =>
                _commit(_draft.copyWith(showHeaderIcon: value)),
          ),
        ),
        SettingRow(
          title: context.l10n.settingIconStyle,
          controlWidth: 220,
          control: FDropdown<String>(
            key: ValueKey('header-icon-${_draft.headerIcon}'),
            initialValue: _headerIcons.containsKey(_draft.headerIcon)
                ? _draft.headerIcon
                : 'emoji',
            isExpanded: true,
            decoration: const InputDecoration(isDense: true),
            items: [
              for (final entry in _headerIcons.entries)
                FDropdownItem(
                  value: entry.key,
                  child: Row(
                    children: [
                      Icon(_headerIconData(entry.key), size: 19),
                      const SizedBox(width: 9),
                      Text(entry.value),
                    ],
                  ),
                ),
              FDropdownItem(
                value: 'emoji',
                child: Row(
                  children: [
                    Icon(Icons.emoji_emotions_outlined, size: 19),
                    SizedBox(width: 9),
                    Text(context.l10n.settingCustomEmoji),
                  ],
                ),
              ),
            ],
            onChanged: (value) {
              if (value == null) return;
              _commit(
                _draft.copyWith(
                  headerIcon: value == 'emoji' ? '⭐' : value,
                  headerImagePath: '',
                ),
              );
            },
          ),
        ),
        if (!_headerIcons.containsKey(_draft.headerIcon)) ...[
          const SizedBox(height: 8),
          FTextFormField(
            key: const ValueKey('header-emoji'),
            initialValue: _draft.headerIcon,
            decoration: InputDecoration(
              labelText: context.l10n.settingEmojiInput,
              hintText: context.l10n.settingEmojiHint,
            ),
            onChanged: (value) =>
                _commit(_draft.copyWith(headerIcon: value.trim())),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (_draft.headerImagePath.isNotEmpty)
              Image.file(
                File(
                  widget.controller.store.resourcePath(
                        _draft.headerImagePath,
                      ) ??
                      '',
                ),
                width: 28,
                height: 28,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Tooltip(
                  message: context.l10n.settingImageUnavailable,
                  child: Icon(Icons.broken_image_outlined),
                ),
              ),
            FButton.icon(
              onPressed: _saving || _pickingImage ? null : _pickHeaderImage,
              icon: _pickingImage
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.image_outlined),
              label: Text(context.l10n.settingChooseImage),
            ),
            if (_draft.headerImagePath.isNotEmpty)
              FTextButton(
                onPressed: () => _commit(_draft.copyWith(headerImagePath: '')),
                child: Text(context.l10n.settingClearImage),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.settingImageDescription,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );

  Future<void> _pickHeaderImage() async {
    setState(() => _pickingImage = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: context.l10n.settingImages,
            extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico'],
          ),
        ],
      );
      if (file == null || !mounted) return;
      final path = await HeaderImageStore(store: widget.controller.store)
          .importFile(file);
      if (mounted) _commit(_draft.copyWith(headerImagePath: path));
    } catch (error) {
      if (!mounted) return;
      final message = error is FormatException
          ? localizeAppError(context, error)
          : context.l10n.settingImageImportFailed;
      setState(() => _error = message);
    } finally {
      if (mounted) setState(() => _pickingImage = false);
    }
  }

  Widget _unitOptions() => _card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingRow(
          title: context.l10n.settingUnitLabels,
          description: context.l10n.settingUnitLabelsDescription,
          control: FDropdown<String>(
            key: const ValueKey('unit-label-mode'),
            initialValue: _draft.unitLabelMode,
            isExpanded: true,
            decoration: const InputDecoration(isDense: true),
            items: [
              FDropdownItem(
                value: 'full',
                child: Text(context.l10n.settingFull),
              ),
              FDropdownItem(
                value: 'compact',
                child: Text(context.l10n.settingCompact),
              ),
              FDropdownItem(
                value: 'custom',
                child: Text(context.l10n.settingCustom),
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                _commit(_draft.copyWith(unitLabelMode: value));
              }
            },
          ),
        ),
        const Divider(height: 1),
        SettingRow(
          title: context.l10n.settingDisplayCurrency,
          description: context.l10n.settingCurrencyDescription,
          control: FDropdown<String>(
            key: const ValueKey('display-currency'),
            initialValue: _draft.displayCurrency,
            isExpanded: true,
            decoration: const InputDecoration(isDense: true),
            items: [
              FDropdownItem(
                value: '',
                child: Text(context.l10n.settingOriginalCurrency),
              ),
              for (final currency in {
                'USD',
                'CNY',
                'EUR',
                'GBP',
                'HKD',
                'JPY',
                'USDT',
                'USDC',
                if (_draft.displayCurrency.isNotEmpty) _draft.displayCurrency,
              })
                FDropdownItem(value: currency, child: Text(currency)),
            ],
            onChanged: (value) {
              if (value != null) {
                _commit(_draft.copyWith(displayCurrency: value));
              }
            },
          ),
        ),
        const SizedBox(height: 8),
        Text(
          context.l10n.settingConversionDescription,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (_draft.unitLabelMode == 'custom') ...[
          const SizedBox(height: 10),
          for (final entry in _draft.unitLabels.entries)
            FListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${entry.key} → ${entry.value}'),
              trailing: FIconButton(
                tooltip: context.l10n.settingDeleteUnitLabel,
                icon: const Icon(Icons.close),
                onPressed: () {
                  final labels = Map<String, String>.of(_draft.unitLabels)
                    ..remove(entry.key);
                  _commit(_draft.copyWith(unitLabels: labels));
                },
              ),
            ),
          FButton.icon(
            onPressed: _addUnitLabel,
            icon: const Icon(Icons.add),
            label: Text(context.l10n.settingAddUnitLabel),
          ),
        ],
        const SizedBox(height: 10),
        for (var i = 0; i < _draft.unitRules.length; i++)
          FListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${_draft.unitRules[i].sourceUnit} → ${_draft.unitRules[i].targetUnit}',
            ),
            subtitle: Text(
              context.l10n.settingMultiplierSummary(
                _draft.unitRules[i].multiplier,
              ),
            ),
            trailing: FIconButton(
              tooltip: context.l10n.settingDeleteUnitRule,
              icon: const Icon(Icons.close),
              onPressed: () => _commit(
                _draft.copyWith(
                  unitRules: [
                    for (var j = 0; j < _draft.unitRules.length; j++)
                      if (j != i) _draft.unitRules[j],
                  ],
                ),
              ),
            ),
          ),
        FButton.icon(
          onPressed: _addUnitRule,
          icon: const Icon(Icons.add),
          label: Text(context.l10n.settingAddUnitRule),
        ),
      ],
    ),
  );

  Future<void> _addUnitLabel() async {
    var source = '', label = '';
    String? error;
    final result = await showDialog<MapEntry<String, String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) => FAlertDialog(
          scrollable: true,
          title: Text(context.l10n.settingCustomUnitLabel),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FTextFormField(
                  key: const ValueKey('label-source'),
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: context.l10n.settingSourceUnit,
                    hintText: context.l10n.settingUsdtHint,
                  ),
                  onChanged: (value) => source = value.trim(),
                ),
                const SizedBox(height: 10),
                FTextFormField(
                  key: const ValueKey('label-text'),
                  decoration: InputDecoration(
                    labelText: context.l10n.settingDisplayLabel,
                    hintText: context.l10n.settingUHint,
                  ),
                  onChanged: (value) => label = value.trim(),
                ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            FTextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.settingCancel),
            ),
            FFilledButton(
              onPressed: () {
                if (source.isEmpty || label.isEmpty) {
                  refresh(() => error = context.l10n.settingUnitLabelRequired);
                  return;
                }
                Navigator.pop(context, MapEntry(source, label));
              },
              child: Text(context.l10n.settingSaveLabel),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      _commit(
        _draft.copyWith(
          unitLabels: {
            for (final entry in _draft.unitLabels.entries)
              if (_unitKey(entry.key) != _unitKey(result.key))
                entry.key: entry.value,
            result.key: result.value,
          },
        ),
      );
    }
  }

  Future<void> _addUnitRule() async {
    var source = '', target = '', multiplier = '';
    String? error;
    final result = await showDialog<UnitConversionRule>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) => FAlertDialog(
          scrollable: true,
          title: Text(context.l10n.settingCustomConversion),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FTextFormField(
                  key: const ValueKey('rule-source'),
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: context.l10n.settingSourceUnit,
                    hintText: context.l10n.settingOunceHint,
                  ),
                  onChanged: (value) => source = value.trim(),
                ),
                const SizedBox(height: 10),
                FTextFormField(
                  key: const ValueKey('rule-target'),
                  decoration: InputDecoration(
                    labelText: context.l10n.settingTargetUnit,
                    hintText: context.l10n.settingGramHint,
                  ),
                  onChanged: (value) => target = value.trim(),
                ),
                const SizedBox(height: 10),
                FTextFormField(
                  key: const ValueKey('rule-multiplier'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: context.l10n.settingMultiplier,
                    hintText: context.l10n.settingMultiplierHint,
                  ),
                  onChanged: (value) => multiplier = value.trim(),
                ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            FTextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.settingCancel),
            ),
            FFilledButton(
              onPressed: () {
                final number = double.tryParse(multiplier);
                if (source.isEmpty ||
                    target.isEmpty ||
                    number == null ||
                    !number.isFinite ||
                    number <= 0) {
                  refresh(() => error = context.l10n.settingUnitRuleRequired);
                  return;
                }
                Navigator.pop(
                  context,
                  UnitConversionRule(
                    sourceUnit: source,
                    targetUnit: target,
                    multiplier: number,
                  ),
                );
              },
              child: Text(context.l10n.settingSaveRule),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      _commit(
        _draft.copyWith(
          unitRules: [
            ..._draft.unitRules.where(
              (rule) =>
                  _unitKey(rule.sourceUnit) != _unitKey(result.sourceUnit),
            ),
            result,
          ],
        ),
      );
    }
  }

  String _unitKey(String value) => value.trim().toUpperCase();

  /// Ask for a font and make sure it can be loaded, without applying it.
  ///
  /// Split out from [_pickFont] so the declared view can own the write while
  /// sharing the dialog, the load check and the error handling.
  Future<String?> _chooseFont(bool numbers) async {
    final font = await showDialog<String>(
      context: context,
      builder: (context) => _FontDialog(
        fonts: _fonts,
        current: numbers ? _draft.numberFontFamily : _draft.fontFamily,
        hint: numbers ? context.l10n.settingNumberFontHint : null,
        highlightMonospace: numbers,
      ),
    );
    if (font == null || !mounted) return null;
    setState(() => _loadingDraft = true);
    try {
      await SystemFonts.ensureLoaded(font);
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.settingFontLoadFailed);
      }
      return null;
    } finally {
      if (mounted) setState(() => _loadingDraft = false);
    }
    return font;
  }
}

class _SettingTag extends StatelessWidget {
  const _SettingTag({required this.label, this.avatar});
  final Widget label;
  final Widget? avatar;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (avatar != null) ...[avatar!, const SizedBox(width: 6)],
        Flexible(
          child: DefaultTextStyle(
            style: Theme.of(context).textTheme.bodySmall!,
            child: label,
          ),
        ),
      ],
    ),
  );
}
