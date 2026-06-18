import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/data/business_types.dart';
import 'package:reebaplus_pos/core/data/currencies.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// CEO Settings > Business Info (§10.1). Edits the business name, type, and
/// currency. Name/type persist to the `businesses` row via [BusinessesDao];
/// currency is the synced `settings` key `default_currency`.
class BusinessInfoScreen extends ConsumerStatefulWidget {
  const BusinessInfoScreen({super.key});

  @override
  ConsumerState<BusinessInfoScreen> createState() => _BusinessInfoScreenState();
}

class _BusinessInfoScreenState extends ConsumerState<BusinessInfoScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  String? _type;
  String _currency = kDefaultCurrency;
  bool _loading = true;
  bool _saving = false;

  /// Distinct currency codes offered in the picker, always including the
  /// default and whatever the business already has.
  late final List<String> _currencyCodes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    final bizId = db.currentBusinessId;
    final biz = bizId != null
        ? await (db.select(
            db.businesses,
          )..where((t) => t.id.equals(bizId))).getSingleOrNull()
        : (await db.select(db.businesses).get()).firstOrNull;
    final currency = await db.settingsDao.get('default_currency');

    if (!mounted) return;
    setState(() {
      _nameController.text = biz?.name ?? '';
      _phoneController.text = biz?.phone ?? '';
      // DB stores 'Beer distributor' (legacy canonical); display as 'Beverage distributor'.
      var loadedType = biz?.type;
      if (loadedType == 'Beer distributor') {
        loadedType = 'Beverage distributor';
      }
      _type = kBusinessTypes.contains(loadedType) ? loadedType : null;
      // Normalise legacy label-style values (e.g. "NGN (₦)") to a clean ISO
      // code so the picker shows "NGN" and saving repairs the stored value.
      _currency = normalizeCurrencyCode(currency);
      _currencyCodes = {
        kDefaultCurrency,
        ...kCountryCurrency.values,
        _currency,
      }.toList()..sort();
      _loading = false;
    });
  }

  Future<void> _save() async {
    // Defense-in-depth (hard rule #6): the drawer hides the entry, but the
    // write site re-checks too. ref.read (not hasPermission/watch) — this is a
    // callback, matching staff_detail_screen.dart.
    if (!ref.read(currentUserPermissionsProvider).contains('settings.manage')) {
      AppNotification.showError(
        context,
        'You don\'t have permission to do that.',
      );
      return;
    }
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      AppNotification.showError(context, 'Business name can\'t be empty.');
      return;
    }

    setState(() => _saving = true);
    final db = ref.read(databaseProvider);
    try {
      // Map display label back to DB canonical before writing.
      final dbType = _type == 'Beverage distributor'
          ? 'Beer distributor'
          : _type;
      await db.businessesDao.updateInfo(
        name: name,
        type: dbType,
        phone: _phoneController.text.trim(),
      );
      await db.settingsDao.set('default_currency', _currency);
      await db.activityLogDao.log(
        action: 'settings.business_info.update',
        description: 'Updated business info (name, type, currency)',
        staffId: db.currentUserId,
      );
      if (!mounted) return;
      AppNotification.showSuccess(context, 'Business info saved.');
    } catch (_) {
      if (!mounted) return;
      AppNotification.showError(context, 'Couldn\'t save business info.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Screen-level gate (hard rule #6) + keeps the permission chain warm for
    // the save-site guard.
    final canManage = hasPermission(ref, 'settings.manage');
    return GlassyScaffold(
      title: 'Business Info',
      body: !canManage
          ? const SettingsNoAccess()
          : _loading
          ? const SizedBox.shrink()
          : SettingsFadeIn(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  24,
                  24,
                  24,
                  24 + context.deviceBottomPadding,
                ),
                children: [
                  const SettingsSectionTitle('Business'),
                  const SizedBox(height: 16),
                  GlassyCard(
                    padding: const EdgeInsets.all(16),
                    radius: 16,
                    child: Column(
                      children: [
                        TextField(
                          controller: _nameController,
                          textCapitalization: TextCapitalization.words,
                          decoration: AppDecorations.authInputDecoration(
                            context,
                            label: 'Business name',
                            prefixIcon: Icons.business_rounded,
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _phoneController,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: AppDecorations.authInputDecoration(
                            context,
                            label: 'Phone number',
                            prefixIcon: Icons.phone_rounded,
                          ),
                        ),
                        const SizedBox(height: 16),
                        AppDropdown<String>(
                          value: _type,
                          isExpanded: true,
                          labelText: 'Business type',
                          prefixIcon: const Icon(Icons.category_rounded, size: 20),
                          items: [
                            for (final type in kBusinessTypes)
                              DropdownMenuItem(value: type, child: Text(type)),
                          ],
                          onChanged: (v) => setState(() => _type = v),
                        ),
                        const SizedBox(height: 16),
                        AppDropdown<String>(
                          value: _currency,
                          isExpanded: true,
                          labelText: 'Currency',
                          prefixIcon: const Icon(Icons.payments_rounded, size: 20),
                          items: [
                            for (final code in _currencyCodes)
                              DropdownMenuItem(value: code, child: Text(code)),
                          ],
                          onChanged: (v) =>
                              setState(() => _currency = v ?? _currency),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  _SaveButton(saving: _saving, onPressed: _save),
                ],
              ),
            ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  final bool saving;
  final VoidCallback onPressed;
  const _SaveButton({required this.saving, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: saving ? null : onPressed,
      child: Opacity(
        opacity: saving ? 0.6 : 1,
        child: Container(
          height: 54,
          alignment: Alignment.center,
          decoration: AppDecorations.primaryGradient(context, radius: 14),
          child: const Text(
            'Save changes',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
