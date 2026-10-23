/// Strings for the declared settings page.
///
/// Kept next to the view instead of the ARB catalog because these are page
/// chrome, not user-facing product copy: they exist for every app that uses the
/// contract and would otherwise be copied into every catalog.
class TiSettingsStrings {
  const TiSettingsStrings(this.chinese);

  final bool chinese;

  String get search => chinese ? '搜索设置' : 'Search settings';
  String get changed => chinese ? '已改' : 'Changed';
  String get unit => chinese ? '项' : '';
  String get reset => chinese ? '恢复默认' : 'Reset to default';
  String get resetGroup => chinese ? '恢复本组' : 'Reset group';
  String get resetAll => chinese ? '全部恢复默认' : 'Reset everything';
  String get resetAllConfirm => chinese
      ? '所有设置将回到默认值，包括你调过的每一项。这一步不能撤销。'
      : 'Every setting goes back to its default, including the ones you tuned. '
            'This cannot be undone.';
  String get cancel => chinese ? '取消' : 'Cancel';
  String get confirm => chinese ? '恢复默认' : 'Reset';
  String get exportJson => chinese ? '导出设置' : 'Export settings';
  String get importJson => chinese ? '导入设置' : 'Import settings';
  String get exportEmpty => chinese
      ? '还没有改过任何设置，导出的文件是空的。'
      : 'Nothing changed yet, so the export is empty.';
  String get exportDone => chinese ? '已导出' : 'Exported';
  String get importDone => chinese ? '已恢复' : 'Restored';
  String get importSkipped => chinese ? '跳过' : 'Skipped';
  String get importFailed =>
      chinese ? '这个文件读不出设置。' : 'That file does not contain settings.';
  String get advanced => chinese ? '高级' : 'Advanced';
  String get experimental => chinese ? '实验' : 'Experimental';
  String get needsRestart => chinese ? '需重启生效' : 'needs a restart';
  String restartBanner(int count) => chinese
      ? '有 $count 项需要重启后才生效。'
      : '$count change${count == 1 ? '' : 's'} take effect after a restart.';
  String get restartNow => chinese ? '立即重启' : 'Restart now';
  String get searchEmpty => chinese ? '没有匹配的设置。' : 'No settings match that.';
  String get noSettings => chinese ? '这里还没有设置项。' : 'No settings here yet.';
  String get unsupportedControl =>
      chinese ? '这个控件还没有实现。' : 'This control is not implemented yet.';
  String get more => chinese ? '更多' : 'More';
}
