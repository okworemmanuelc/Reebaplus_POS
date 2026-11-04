import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/shared/widgets/sales_parts.dart';

/// Edit the deposit paid for one brand, at Checkout and on an edit (#732).
/// Pre-fills [savedKobo] (blank = none); the "Use full" shortcut fills
/// [fullKobo]; clearing or 0 marks the brand "No deposit" (crate-track).
/// Modal-style sheet (back / Save only). Amounts are kobo-exact both ways (#401),
/// and an amount above [fullKobo] can't be saved: an inline message shows and
/// Save is disabled. Returns the saved kobo, or null when dismissed.
///
/// [onRootNavigator] — opened from a pop-up, so it sits outside `MainLayout` and
/// must lift itself above the keyboard.
Future<int?> showCrateDepositSheet(
  BuildContext context, {
  required String name,
  required int fullKobo,
  required int savedKobo,
  Key? sheetKey,
  bool onRootNavigator = false,
}) {
  final ctrl = TextEditingController(
    text: savedKobo == 0 ? '' : koboToInputText(savedKobo),
  );
  int enteredKobo() => (parseCurrency(ctrl.text) * 100).round();
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (sheetCtx) {
      final theme = Theme.of(sheetCtx);
      final primary = theme.colorScheme.primary;
      final subtext =
          theme.textTheme.bodySmall?.color ?? theme.iconTheme.color!;
      final fixed = theme.extension<AppFixedColors>() ?? AppFixedColors.light;
      return SingleChildScrollView(
        key: sheetKey,
        // nav-only inset (NOT deviceBottomInset) at Checkout, which is pushed on
        // the TAB navigator under MainLayout — whose Scaffold
        // (resizeToAvoidBottomInset defaults true) already resizes the tab body
        // up by the keyboard, lifting this sheet above it. Adding the keyboard
        // again via deviceBottomInset double-counts it and the sheet leaps up
        // "like an extra keyboard". deviceBottomPadding clears the system nav
        // bar when the keyboard is down and collapses to 0 when it's up (the
        // resize covers that case).
        padding: EdgeInsets.fromLTRB(
          sheetCtx.getRSize(20),
          sheetCtx.getRSize(12),
          sheetCtx.getRSize(20),
          (onRootNavigator
                  ? sheetCtx.deviceBottomInset
                  : sheetCtx.deviceBottomPadding) +
              sheetCtx.getRSize(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SalesSheetHeader(
              title: 'Deposit — $name',
              leading: const IconTile(
                icon: AppIcons.crates,
                tone: IconTileTone.warning,
                size: 44,
              ),
            ),
            SizedBox(height: sheetCtx.getRSize(8)),
            Text(
              'Full deposit is ${formatCurrency(fullKobo / 100.0)}. '
              'Leave blank or 0 for no deposit (crates tracked instead).',
              style: sheetCtx.regularStyle(13).copyWith(color: subtext),
            ),
            SizedBox(height: sheetCtx.getRSize(16)),
            AppInput(
              controller: ctrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [CurrencyInputFormatter()],
              autofocus: true,
              prefixText: '$activeCurrencySymbol ',
              hintText: '0',
            ),
            SizedBox(height: sheetCtx.getRSize(8)),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, kMinInteractiveDimension),
                  foregroundColor: primary,
                  textStyle: sheetCtx.boldStyle(13),
                ),
                onPressed: () {
                  ctrl.text = koboToInputText(fullKobo);
                },
                icon: AppIcon(AppIcons.magic, size: sheetCtx.getRSize(16)),
                label: Text('Use full (${formatCurrency(fullKobo / 100.0)})'),
              ),
            ),
            // Rebuilds the cap message + Save as the amount changes.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: ctrl,
              builder: (_, _, _) {
                final overFull = enteredKobo() > fullKobo;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (overFull)
                      Padding(
                        padding: EdgeInsets.only(top: sheetCtx.getRSize(4)),
                        child: Text(
                          "Can't be more than the full deposit "
                          '$activeCurrencySymbol${koboToInputText(fullKobo)}',
                          style: sheetCtx
                              .semiBoldStyle(12)
                              .copyWith(color: fixed.danger),
                        ),
                      ),
                    SizedBox(height: sheetCtx.getRSize(12)),
                    Row(
                      children: [
                        Expanded(
                          child: AppButton(
                            text: 'Back',
                            variant: AppButtonVariant.ghost,
                            onPressed: () => Navigator.pop(sheetCtx),
                          ),
                        ),
                        SizedBox(width: sheetCtx.getRSize(12)),
                        Expanded(
                          child: AppButton(
                            text: 'Save',
                            variant: AppButtonVariant.primary,
                            onPressed: overFull
                                ? null
                                : () {
                                    final val = enteredKobo();
                                    Navigator.pop(sheetCtx, val < 0 ? 0 : val);
                                  },
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      );
    },
  );
}
