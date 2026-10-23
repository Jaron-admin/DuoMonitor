import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../l10n/l10n.dart';
import 'fluent_controls.dart';

class PriceColorSettings extends StatelessWidget {
  const PriceColorSettings({
    super.key,
    required this.config,
    required this.onChanged,
  });

  final AppConfig config;
  final ValueChanged<AppConfig> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FDropdown<String>(
          key: const ValueKey('price-color-mode'),
          initialValue: config.priceColorMode,
          decoration: InputDecoration(labelText: l10n.settingPriceColor),
          items: [
            FDropdownItem(
              value: 'plain',
              child: Text(l10n.settingPriceColorPlain),
            ),
            FDropdownItem(
              value: 'theme',
              child: Text(l10n.settingPriceColorTheme),
            ),
            FDropdownItem(
              value: 'greenUp',
              child: Text(l10n.settingPriceColorGreenUp),
            ),
            FDropdownItem(
              value: 'redUp',
              child: Text(l10n.settingPriceColorRedUp),
            ),
          ],
          onChanged: (value) {
            if (value != null) {
              onChanged(config.copyWith(priceColorMode: value));
            }
          },
        ),
        const SizedBox(height: 8),
        Text(
          l10n.settingPriceColorHint,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
