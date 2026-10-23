part of 'settings_page.dart';

class _AssetDialog extends StatefulWidget {
  const _AssetDialog();
  @override
  State<_AssetDialog> createState() => _AssetDialogState();
}

class _AssetDialogState extends State<_AssetDialog> {
  String _provider = 'OKX';
  final _symbol = TextEditingController();
  final _name = TextEditingController();
  String? _error;
  @override
  void dispose() {
    _symbol.dispose();
    _name.dispose();
    super.dispose();
  }

  void _accept() {
    var symbol = _symbol.text.trim().toUpperCase();
    if (symbol.isEmpty || !RegExp(r'^[A-Z0-9.^=\-]{1,32}$').hasMatch(symbol)) {
      setState(() => _error = context.l10n.settingInvalidSymbol);
      return;
    }
    if (_provider == 'YAHOO' && RegExp(r'^\d{6}$').hasMatch(symbol)) {
      symbol = '$symbol.${symbol.startsWith('6') ? 'SS' : 'SZ'}';
    }
    final equity = _provider == 'YAHOO';
    final currency = inferCurrency(_provider, symbol);
    Navigator.pop(
      context,
      Asset(
        id: '$_provider:$symbol',
        provider: _provider,
        symbol: symbol,
        name: _name.text.trim().isEmpty ? symbol : _name.text.trim(),
        kind: equity ? MarketKind.equity : MarketKind.crypto,
        currency: currency,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FAlertDialog(
    title: Text(context.l10n.settingAddSymbolDialog),
    content: SizedBox(
      width: 430,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FDropdown<String>(
            initialValue: _provider,
            decoration: InputDecoration(
              labelText: context.l10n.settingProvider,
            ),
            items: [
              FDropdownItem(value: 'OKX', child: Text('OKX')),
              FDropdownItem(value: 'BINANCE', child: Text('Binance')),
              FDropdownItem(value: 'KUCOIN', child: Text('KuCoin')),
              FDropdownItem(
                value: 'YAHOO',
                child: Text(context.l10n.settingYahooMarkets),
              ),
            ],
            onChanged: (value) => setState(() => _provider = value!),
          ),
          const SizedBox(height: 14),
          FTextField(
            controller: _symbol,
            autofocus: true,
            decoration: InputDecoration(
              labelText: context.l10n.settingSymbol,
              hintText: _provider == 'YAHOO'
                  ? context.l10n.settingYahooHint
                  : _provider == 'BINANCE'
                  ? 'BTCUSDT'
                  : 'BTC-USDT',
            ),
          ),
          const SizedBox(height: 14),
          FTextField(
            controller: _name,
            decoration: InputDecoration(
              labelText: context.l10n.settingOptionalName,
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
      FFilledButton(onPressed: _accept, child: Text(context.l10n.settingAdd)),
    ],
  );
}

class _FontDialog extends StatefulWidget {
  const _FontDialog({
    required this.fonts,
    required this.current,
    this.hint,
    this.highlightMonospace = false,
  });
  final List<String> fonts;
  final String current;
  final String? hint;
  final bool highlightMonospace;
  @override
  State<_FontDialog> createState() => _FontDialogState();
}

class _FontDialogState extends State<_FontDialog> {
  String _search = '';
  final _loads = <String, Future<void>>{};
  @override
  Widget build(BuildContext context) {
    final fonts = widget.fonts
        .where((font) => font.toLowerCase().contains(_search.toLowerCase()))
        .toList();
    return FAlertDialog(
      title: Text(context.l10n.settingChooseFont),
      content: SizedBox(
        width: 480,
        height: (MediaQuery.sizeOf(context).height - 220).clamp(160.0, 420.0),
        child: Column(
          children: [
            FTextField(
              autofocus: true,
              decoration: InputDecoration(
                labelText: context.l10n.settingSearchFonts,
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => _search = value),
            ),
            if (widget.hint != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.hint!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: fonts.isEmpty
                  ? Center(child: Text(context.l10n.settingNoFonts))
                  : ListView.builder(
                      itemCount: fonts.length,
                      itemBuilder: (context, index) => FutureBuilder<void>(
                        future: _loads.putIfAbsent(
                          fonts[index],
                          () => SystemFonts.ensureLoaded(fonts[index]),
                        ),
                        builder: (context, snapshot) => FListTile(
                          selected: fonts[index] == widget.current,
                          title: Text(
                            fonts[index],
                            style: TextStyle(
                              fontFamily: SystemFonts.family(fonts[index]),
                            ),
                          ),
                          subtitle: snapshot.hasError
                              ? Text(
                                  context.l10n.settingFontUnavailable,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                )
                              : Text(
                                  context.l10n.settingFontSample,
                                  style: TextStyle(
                                    fontFamily: SystemFonts.family(
                                      fonts[index],
                                    ),
                                  ),
                                ),
                          trailing:
                              widget.highlightMonospace &&
                                  isMonospaceFontFamily(fonts[index])
                              ? Text(context.l10n.settingMonospaceFont)
                              : snapshot.connectionState == ConnectionState.done
                              ? null
                              : const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                          onTap:
                              snapshot.connectionState !=
                                      ConnectionState.done ||
                                  snapshot.hasError
                              ? null
                              : () => Navigator.pop(context, fonts[index]),
                        ),
                      ),
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
      ],
    );
  }
}
