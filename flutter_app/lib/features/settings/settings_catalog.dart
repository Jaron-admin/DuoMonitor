import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../l10n/metrics_strings.dart';

class SettingsCategory {
  const SettingsCategory(this.id, this.icon);
  final String id;
  final IconData icon;

  String title(AppLocalizations l10n) {
    final zh = l10n.localeName.startsWith('zh');
    return switch (id) {
      'general' => zh ? '通用' : 'General',
      'appearance' => l10n.settingAppearance,
      'display' => zh ? '显示' : 'Display',
      'privacy' => zh ? '隐私与数据' : 'Privacy and data',
      _ => zh ? '关于' : 'About',
    };
  }
}

/// Fixed group order from the shared settings contract:
/// general -> appearance -> app-specific (max three) -> notifications ->
/// privacy -> advanced -> about.
///
/// Groups with nothing in them are dropped from the rail, but the order of the
/// rest never changes. `notifications` and `advanced` have no settings in this
/// app yet, so they are absent rather than empty.
const settingsCategories = [
  SettingsCategory('general', Icons.tune_rounded),
  SettingsCategory('appearance', Icons.palette_outlined),
  SettingsCategory('display', Icons.view_agenda_outlined),
  SettingsCategory('privacy', Icons.lock_outline_rounded),
  SettingsCategory('about', Icons.info_outline_rounded),
];

class SettingLocation {
  const SettingLocation(
    this.group,
    this.anchor,
    this.searchTitle,
    this.keywords,
  );

  /// Rail id, not an index: reordering the rail must not silently retarget
  /// search results. Resolved through [section] when the jump happens.
  final String group;
  final String anchor;
  final String searchTitle;
  final String keywords;

  int get section {
    final index = settingsCategories.indexWhere((entry) => entry.id == group);
    return index < 0 ? 0 : index;
  }

  String title(AppLocalizations l10n) => switch (anchor) {
    'assets' => l10n.settingCatalogAssets,
    'asset-order' => l10n.settingCatalogOrder,
    'sources' => l10n.settingCatalogApi,
    'default-rows' => l10n.settingDefaultRows,
    'panel-layout' => l10n.settingLayout,
    'price-color' => l10n.settingPriceColor,
    'custom-rows' => l10n.settingCatalogRows,
    'language' => l10n.settingLanguage,
    'fonts' => l10n.settingCatalogFonts,
    'font-size' => l10n.settingCatalogSpacing,
    'themes' => l10n.settingCatalogThemes,
    'opacity' => l10n.settingOpacity,
    'header' => l10n.settingCatalogHeader,
    'units' => l10n.settingCatalogUnits,
    'window' => l10n.settingCatalogWindow,
    'tray' => l10n.settingCatalogTray,
    'metrics' => MetricsStrings(l10n.localeName.startsWith('zh')).system,
    _ => l10n.settingStorage,
  };

  bool matches(String query) {
    final text = '${settingsCategories[section].id} $searchTitle $keywords'
        .toLowerCase();
    return query
        .toLowerCase()
        .trim()
        .split(RegExp(r'\s+'))
        .every(text.contains);
  }
}

const settingsLocations = [
  SettingLocation(
    'display',
    'panel-layout',
    '列数与行情布局',
    '单列 双列 多列 横向 纵向 24h 涨跌幅 columns horizontal vertical orientation price change percent layout',
  ),
  SettingLocation(
    'display',
    'metrics',
    '系统监测',
    'cpu memory ram gpu vram network upload download disk system monitor 内存 显卡 显存 网速 上传 下载 磁盘 采样 系统 指标',
  ),
  SettingLocation(
    'display',
    'assets',
    '选择行情',
    '币种 加密货币 股票 ETF 搜索 代码 instruments currencies crypto stocks search symbol provider watchlist',
  ),
  SettingLocation(
    'display',
    'asset-order',
    '行情显示顺序',
    '排序 拖动 拖拽 上移 下移 已关注 order reorder sort drag up down watchlist',
  ),
  SettingLocation(
    'display',
    'sources',
    '自定义 API',
    '数据源 HTTPS 接口 请求头 密钥 刷新 字段 custom API sources headers keys refresh fields',
  ),
  SettingLocation(
    'display',
    'default-rows',
    '显示默认行情',
    '行情列表 名称 价格 涨跌 default quotes rows list names prices changes',
  ),
  SettingLocation(
    'display',
    'custom-rows',
    '自由显示行与模板',
    '布局 组合 文字 天气 汇率 GitHub custom rows templates layout text weather exchange rates',
  ),
  SettingLocation(
    'general',
    'language',
    '语言',
    '中文 英文 跟随系统 简体 language English Chinese system',
  ),
  SettingLocation(
    'appearance',
    'price-color',
    '价格颜色',
    '涨跌 红绿 黑白 主题文字 上次刷新 price color red green neutral last refresh',
  ),
  SettingLocation(
    'appearance',
    'fonts',
    '文字与数字字体',
    '系统字体 中文 数字 等宽 monospace text number system fonts',
  ),
  SettingLocation(
    'appearance',
    'font-size',
    '字号与行间距',
    '文字大小 大小 间隔 font size row spacing',
  ),
  SettingLocation(
    'appearance',
    'themes',
    '浅色与深色主题',
    '配色 背景 颜色 取色 自定义 新建 预设 跟随系统 Fluent Catppuccin Nord Solarized theme light dark colors custom presets follow system',
  ),
  SettingLocation(
    'appearance',
    'opacity',
    '悬浮窗透明度',
    '不透明度 背景 透明 panel transparency opacity background',
  ),
  SettingLocation(
    'appearance',
    'header',
    '窗口标题与图标',
    '名称 图片 表情 隐藏标题 header title name icon image emoji hide',
  ),
  SettingLocation(
    'display',
    'units',
    '单位与显示货币',
    '换算 人民币 美元 CNY USD 简写 标签 倍率 units currency conversion short labels multiplier',
  ),
  SettingLocation(
    'general',
    'window',
    '窗口置顶',
    '置顶 悬浮 大小 移动 window always on top size move',
  ),
  SettingLocation(
    'general',
    'tray',
    '隐藏与托盘恢复',
    '双击 隐藏 托盘 单击 恢复 hide restore tray double click',
  ),
  SettingLocation(
    'privacy',
    'storage',
    '导入与数据位置',
    '旧版 Python 设置文件 配置 文件夹 路径 便携 系统应用数据 import legacy storage data location config folder path portable system app data',
  ),
];

/// A compact setting keeps its label and control together at small widths.
class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.title,
    this.description,
    required this.control,
    this.controlWidth = 180,
  });

  final String title;
  final String? description;
  final Widget control;
  final double controlWidth;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final label = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.bodyMedium),
            if (description != null) ...[
              const SizedBox(height: 3),
              Text(
                description!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ],
        );
        if (constraints.maxWidth < 420 && controlWidth > 100) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              label,
              const SizedBox(height: 8),
              Semantics(label: title, child: control),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: label),
            const SizedBox(width: 16),
            SizedBox(
              width: controlWidth,
              child: Semantics(label: title, child: control),
            ),
          ],
        );
      },
    ),
  );
}
