import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/data/area_selection.dart';
import 'package:reebaplus_pos/core/data/countries.dart';
import 'package:reebaplus_pos/core/data/nigerian_lgas.dart';
import 'package:reebaplus_pos/core/data/nigerian_states.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/l10n/area_localizations.dart';
import 'package:reebaplus_pos/l10n/area_localizations_en.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';

/// Opens the shared, offline area chooser. Dismissing returns null and never
/// changes the caller's saved value. No business/session providers are read.
Future<AreaSelection?> showAreaPicker(
  BuildContext context, {
  AreaSelection? initialValue,
  bool allowWholeState = false,
}) => showModalBottomSheet<AreaSelection>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  constraints: const BoxConstraints(maxWidth: 640),
  builder: (sheetContext) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
    child: FractionallySizedBox(
      heightFactor: 0.9,
      child: AreaPicker(
        initialValue: initialValue,
        allowWholeState: allowWholeState,
        onSelected: (area) => Navigator.of(sheetContext).pop(area),
        onCancel: () => Navigator.of(sheetContext).pop(),
      ),
    ),
  ),
);

AreaLocalizations _strings(BuildContext context) =>
    AreaLocalizations.of(context) ?? AreaLocalizationsEn();

enum _AreaStep { country, state, lga, foreign }

/// Reusable chooser for store areas, delivery areas and shopper addresses.
/// Embed with bounded height or use [showAreaPicker]. All draft state is local
/// and disposable. The caller alone persists a confirmed [AreaSelection].
class AreaPicker extends StatefulWidget {
  const AreaPicker({
    super.key,
    required this.onSelected,
    required this.onCancel,
    this.initialValue,
    this.allowWholeState = false,
  });

  final ValueChanged<AreaSelection> onSelected;
  final VoidCallback onCancel;
  final AreaSelection? initialValue;
  final bool allowWholeState;

  @override
  State<AreaPicker> createState() => _AreaPickerState();
}

class _AreaPickerState extends State<AreaPicker> {
  final _query = TextEditingController();
  final _foreignState = TextEditingController();
  final _foreignLga = TextEditingController();
  final _scroll = ScrollController();
  final _form = GlobalKey<FormState>();
  late String _country;
  String? _state;
  bool _foreignWholeState = false;
  late _AreaStep _step;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialValue;
    _country = initial?.country.trim() ?? kDefaultCountry;
    if (_country.isEmpty || _country.toLowerCase() == 'nigeria') {
      _country = kDefaultCountry;
    }
    _state = initial?.state;
    if (_country == kDefaultCountry) {
      if (!kNigerianStates.contains(_state)) _state = null;
      _step = _state == null ? _AreaStep.state : _AreaStep.lga;
    } else {
      _foreignState.text = initial?.state ?? '';
      _foreignLga.text = initial?.lga ?? '';
      _foreignWholeState = widget.allowWholeState && initial?.isWholeState == true;
      _step = _AreaStep.foreign;
    }
  }

  @override
  void dispose() {
    _query.dispose();
    _foreignState.dispose();
    _foreignLga.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _go(_AreaStep step) {
    FocusScope.of(context).unfocus();
    setState(() {
      _step = step;
      _query.clear();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _chooseCountry(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    final country = kCountries.firstWhere(
      (country) => country.toLowerCase() == trimmed.toLowerCase(),
      orElse: () => trimmed,
    );
    if (country != _country) {
      _state = null;
      _foreignState.clear();
      _foreignLga.clear();
      _foreignWholeState = false;
    }
    _country = country;
    _go(country == kDefaultCountry ? _AreaStep.state : _AreaStep.foreign);
  }

  List<String> get _options {
    final options = switch (_step) {
      _AreaStep.country => kCountries,
      _AreaStep.state => kNigerianStates,
      _AreaStep.lga => kNigerianLgas[_state] ?? const <String>[],
      _AreaStep.foreign => const <String>[],
    };
    final query = _query.text.trim().toLowerCase();
    return options.where((option) => option.toLowerCase().contains(query)).toList()..sort();
  }

  void _chooseOption(String value) {
    switch (_step) {
      case _AreaStep.country:
        _chooseCountry(value);
      case _AreaStep.state:
        _state = value;
        _go(_AreaStep.lga);
      case _AreaStep.lga:
        widget.onSelected(AreaSelection(country: _country, state: _state!, lga: value));
      case _AreaStep.foreign:
        break;
    }
  }

  void _saveForeign() {
    if (!_form.currentState!.validate()) return;
    widget.onSelected(AreaSelection(
      country: _country,
      state: _foreignState.text.trim(),
      lga: _foreignWholeState ? null : _foreignLga.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final strings = _strings(context);
    final theme = Theme.of(context);
    final options = _options;
    final searchLabel = switch (_step) {
      _AreaStep.country => strings.areaSearchCountry,
      _AreaStep.state => strings.areaSearchState,
      _AreaStep.lga => strings.areaSearchLga,
      _AreaStep.foreign => '',
    };
    final canPickWholeState = widget.allowWholeState && _step == _AreaStep.lga;

    // One scroll surface includes header, search, results and foreign form.
    // Short landscape/keyboard windows never leave a zero-height result pane.
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(AppSpacing.borderRadiusXL)),
      clipBehavior: Clip.antiAlias,
      child: ListView(
        controller: _scroll,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(
          context.getRSize(20), context.getRSize(12),
          context.getRSize(20), context.getRSize(20) + context.deviceBottomPadding,
        ),
        children: [
          Center(
            child: Container(
              width: context.getRSize(40),
              height: context.getRSize(4),
              decoration: ShapeDecoration(
                color: theme.dividerColor,
                shape: const StadiumBorder(),
              ),
            ),
          ),
          SizedBox(height: context.getRSize(16)),
          Row(children: [
            const IconTile(icon: AppIcons.location, size: 44),
            SizedBox(width: context.getRSize(12)),
            Expanded(child: Text(strings.areaChoose, style: context.screenTitleStyle)),
            IconButton(
              tooltip: strings.areaClose,
              onPressed: widget.onCancel,
              icon: const Icon(AppIcons.close),
            ),
          ]),
          SizedBox(height: context.getRSize(12)),
          Text(
            _step == _AreaStep.foreign ? strings.areaFreeTextHelp : strings.areaHelp,
            style: theme.textTheme.bodySmall,
          ),
          SizedBox(height: context.getRSize(8)),
          Wrap(spacing: context.getRSize(8), children: [
            TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(0, kMinInteractiveDimension)),
              onPressed: () => _go(_AreaStep.country),
              icon: const Icon(AppIcons.location),
              label: Text(_country),
            ),
            if (_country == kDefaultCountry && _state != null)
              TextButton.icon(
                style: TextButton.styleFrom(minimumSize: const Size(0, kMinInteractiveDimension)),
                onPressed: () => _go(_AreaStep.state),
                icon: const Icon(AppIcons.chevronDown),
                label: Text(_state!),
              ),
          ]),
          SizedBox(height: context.getRSize(8)),
          if (_step == _AreaStep.foreign)
            Form(
              key: _form,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                AppInput(
                  key: const Key('area-foreign-state'),
                  controller: _foreignState,
                  labelText: strings.areaState,
                  textInputAction: TextInputAction.next,
                  validator: (value) => value == null || value.trim().isEmpty
                      ? strings.areaRequired : null,
                ),
                SizedBox(height: context.getRSize(16)),
                if (widget.allowWholeState)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.areaWholeState),
                    value: _foreignWholeState,
                    onChanged: (value) => setState(() => _foreignWholeState = value!),
                  ),
                if (!_foreignWholeState) AppInput(
                  key: const Key('area-foreign-lga'),
                  controller: _foreignLga,
                  labelText: strings.areaLga,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _saveForeign(),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? strings.areaRequired : null,
                ),
                SizedBox(height: context.getRSize(20)),
                AppButton(text: strings.areaUse, onPressed: _saveForeign),
              ]),
            )
          else ...[
            AppInput(
              key: ValueKey('area-search-${_step.name}'),
              controller: _query,
              labelText: searchLabel,
              prefixIcon: const Icon(AppIcons.search),
              textInputAction: TextInputAction.search,
              onChanged: (_) => setState(() {}),
            ),
            SizedBox(height: context.getRSize(12)),
            if (canPickWholeState && _query.text.trim().isEmpty)
              ListTile(
                key: const Key('area-whole-state'),
                minTileHeight: kMinInteractiveDimension,
                contentPadding: EdgeInsets.symmetric(vertical: context.getRSize(8)),
                leading: Icon(AppIcons.checkCircle, color: theme.colorScheme.primary),
                title: Text(strings.areaWholeState, style: theme.textTheme.titleMedium),
                subtitle: Text(strings.areaWholeStateHelp, style: theme.textTheme.bodySmall),
                onTap: () => widget.onSelected(AreaSelection(country: _country, state: _state!)),
              ),
            if (options.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: context.getRSize(20)),
                child: Text(strings.areaNoMatches, style: theme.textTheme.bodyMedium),
              ),
            for (final option in options)
              ListTile(
                key: ValueKey('area-option-$option'),
                minTileHeight: kMinInteractiveDimension,
                contentPadding: EdgeInsets.zero,
                title: Text(option, style: theme.textTheme.bodyMedium),
                trailing: Icon(
                  _step == _AreaStep.lga &&
                          _country == widget.initialValue?.country &&
                          _state == widget.initialValue?.state &&
                          option == widget.initialValue?.lga
                      ? AppIcons.check : AppIcons.chevronRight,
                  color: theme.colorScheme.primary,
                ),
                onTap: () => _chooseOption(option),
              ),
            if (_step == _AreaStep.country && _query.text.trim().isNotEmpty)
              AppButton(
                text: strings.areaUseCountry,
                onPressed: () => _chooseCountry(_query.text),
              ),
          ],
        ],
      ),
    );
  }
}
