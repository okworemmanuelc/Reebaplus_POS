import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'package:reebaplus_pos/core/data/business_types.dart';
import 'package:reebaplus_pos/core/data/currencies.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/result.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/settings/vat_settings.dart';
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
  bool _tracksEmptyCrates = true;
  String _currency = kDefaultCurrency;
  // VAT is opt-in and OFF by default (not every business is authorised to
  // charge it). Rate is entered as a percentage and stored as basis points.
  bool _vatEnabled = false;
  final _vatRateController = TextEditingController();
  bool _loading = true;
  bool _saving = false;

  /// Cached local path of the current logo (null = no logo).
  String? _logoLocalPath;

  /// Pending bytes from a newly picked image (not yet saved to cloud).
  /// Non-null means the user picked a new logo but hasn't hit "Save" yet.
  _PendingLogo? _pendingLogo;

  /// True when the user hit "Remove logo" — we clear on next Save.
  bool _pendingRemoveLogo = false;

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
    _vatRateController.dispose();
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
    final vatEnabledRaw = await db.settingsDao.get(kVatEnabledKey);
    final vatBps = parseVatRateBps(await db.settingsDao.get(kVatRateBpsKey));

    // Attempt to resolve a cached local logo path.
    String? logoPath;
    if (biz != null) {
      final svc = ref.read(businessLogoServiceProvider);
      logoPath = await svc.ensureCached(
        businessId: biz.id,
        logoUrl: biz.logoUrl,
      );
    }

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
      _tracksEmptyCrates = biz?.tracksEmptyCrates ?? true;
      // Normalise legacy label-style values (e.g. "NGN (₦)") to a clean ISO
      // code so the picker shows "NGN" and saving repairs the stored value.
      _currency = normalizeCurrencyCode(currency);
      _currencyCodes = {
        kDefaultCurrency,
        ...kCountryCurrency.values,
        _currency,
      }.toList()..sort();
      _vatEnabled = vatEnabledRaw?.trim().toLowerCase() == 'true';
      _vatRateController.text = vatBps > 0
          ? VatConfig(enabled: true, rateBps: vatBps).ratePercentLabel
          : '';
      _logoLocalPath = logoPath;
      _loading = false;
    });
  }

  // ── Logo actions ────────────────────────────────────────────────────────────

  Future<void> _pickLogo() async {
    final svc = ref.read(businessLogoServiceProvider);
    final result = await svc.pickAndProcess(source: ImageSource.gallery);
    switch (result) {
      case Ok(:final value):
        setState(() {
          _pendingLogo = _PendingLogo(value);
          _pendingRemoveLogo = false;
        });
      case Err(:final error):
        if (!mounted) return;
        if (!error.isCancelled) {
          AppNotification.showError(context, 'Could not load image.');
        }
    }
  }

  void _removeLogo() {
    setState(() {
      _pendingLogo = null;
      _pendingRemoveLogo = true;
    });
  }

  // ── Save ────────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    // Defense-in-depth (hard rule #6): the drawer hides the entry, but the
    // write site re-checks too. Fire-time form (allowsNow) — this is a
    // callback, not a build.
    if (!Gates.manageSettings.allowsNow(ref)) {
      showGateDenied(context, Gates.manageSettings);
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

      // -- Logo changes first (get the URL before writing the business row).
      final bizId = db.currentBusinessId;
      String? newLogoUrl;
      bool clearLogo = false;

      if (bizId != null) {
        final svc = ref.read(businessLogoServiceProvider);

        if (_pendingLogo != null) {
          final uploadResult = await svc.save(
            businessId: bizId,
            bytes: _pendingLogo!.bytes,
          );
          switch (uploadResult) {
            case Ok(:final value):
              newLogoUrl = value;
              _logoLocalPath = await svc.localPathFor(bizId);
              _pendingLogo = null;
            case Err():
              if (!mounted) return;
              AppNotification.showError(
                context,
                'Logo upload failed. Other changes will still be saved.',
              );
          }
        } else if (_pendingRemoveLogo) {
          await svc.clear(bizId);
          clearLogo = true;
          _logoLocalPath = null;
          _pendingRemoveLogo = false;
        }
      }

      // -- Business info row.
      await db.businessesDao.updateInfo(
        name: name,
        type: dbType,
        phone: _phoneController.text.trim(),
        tracksEmptyCrates: isCrateBusiness(dbType) ? _tracksEmptyCrates : true,
        logoUrl: clearLogo
            ? ''
            : newLogoUrl ?? const Object(), // sentinel = leave unchanged
      );
      await db.settingsDao.set('default_currency', _currency);
      // VAT (opt-in). Persist the flag always; write the rate (as basis points)
      // only when enabled, defaulting a blank/zero entry so the closing shows no
      // phantom VAT.
      await db.settingsDao.set(kVatEnabledKey, _vatEnabled ? 'true' : 'false');
      if (_vatEnabled) {
        final pct = double.tryParse(_vatRateController.text.trim()) ?? 0;
        final bps = pct <= 0 ? 0 : (pct * 100).round();
        await db.settingsDao.set(kVatRateBpsKey, bps.toString());
      }
      await db.activityLogDao.log(
        action: 'settings.business_info.update',
        description: 'Updated business info (name, type, currency, VAT)',
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

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Screen-level gate (hard rule #6) + keeps the permission chain warm for
    // the save-site guard.
    final canManage = Gates.manageSettings.allows(ref);
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
                  const SettingsSectionTitle('Logo'),
                  const SizedBox(height: 16),
                  GlassyCard(
                    padding: const EdgeInsets.all(16),
                    radius: 16,
                    child: _LogoSection(
                      logoLocalPath: _pendingLogo != null || _pendingRemoveLogo
                          ? null
                          : _logoLocalPath,
                      pendingBytes: _pendingLogo?.bytes,
                      onPick: _pickLogo,
                      onRemove: _logoLocalPath != null ||
                              _pendingLogo != null
                          ? _removeLogo
                          : null,
                    ),
                  ),
                  const SizedBox(height: 24),
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
                          prefixIcon:
                              const Icon(Icons.category_rounded, size: 20),
                          items: [
                            for (final type in kBusinessTypes)
                              DropdownMenuItem(
                                value: type,
                                child: Text(type),
                              ),
                          ],
                          onChanged: (v) => setState(() {
                            _type = v;
                            // Reset to default when type changes.
                            _tracksEmptyCrates = true;
                          }),
                        ),
                        if (isCrateBusiness(_type)) ...[
                          const SizedBox(height: 8),
                          SwitchListTile(
                            value: _tracksEmptyCrates,
                            onChanged: (v) =>
                                setState(() => _tracksEmptyCrates = v),
                            activeThumbColor:
                                Theme.of(context).colorScheme.primary,
                            activeTrackColor: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.35),
                            title: Text(
                              'Track empty crates',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            subtitle: Text(
                              'Enable to track returnable bottles and crate deposits.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ],
                        const SizedBox(height: 16),
                        AppDropdown<String>(
                          value: _currency,
                          isExpanded: true,
                          labelText: 'Currency',
                          prefixIcon:
                              const Icon(Icons.payments_rounded, size: 20),
                          items: [
                            for (final code in _currencyCodes)
                              DropdownMenuItem(
                                value: code,
                                child: Text(code),
                              ),
                          ],
                          onChanged: (v) =>
                              setState(() => _currency = v ?? _currency),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  const SettingsSectionTitle('Tax'),
                  const SizedBox(height: 16),
                  GlassyCard(
                    padding: const EdgeInsets.all(16),
                    radius: 16,
                    child: Column(
                      children: [
                        SwitchListTile(
                          value: _vatEnabled,
                          onChanged: (v) => setState(() {
                            _vatEnabled = v;
                            // Prefill the standard rate the first time it's
                            // enabled with a blank field.
                            if (v && _vatRateController.text.trim().isEmpty) {
                              _vatRateController.text = const VatConfig(
                                enabled: true,
                                rateBps: kDefaultVatRateBps,
                              ).ratePercentLabel;
                            }
                          }),
                          activeThumbColor:
                              Theme.of(context).colorScheme.primary,
                          activeTrackColor: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.35),
                          title: Text(
                            'Charge VAT',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          subtitle: Text(
                            'Only enable if your business is registered to '
                            'charge VAT. It appears on the daily closing.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                        if (_vatEnabled) ...[
                          const SizedBox(height: 8),
                          TextField(
                            controller: _vatRateController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'^\d*\.?\d*'),
                              ),
                            ],
                            decoration: AppDecorations.authInputDecoration(
                              context,
                              label: 'VAT rate (%)',
                              prefixIcon: Icons.percent_rounded,
                            ),
                          ),
                        ],
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

// ── Logo section widget ────────────────────────────────────────────────────

class _LogoSection extends StatelessWidget {
  const _LogoSection({
    required this.logoLocalPath,
    required this.pendingBytes,
    required this.onPick,
    required this.onRemove,
  });

  /// Existing cached logo path — null when no logo.
  final String? logoLocalPath;

  /// Freshly picked bytes (before save) — overrides [logoLocalPath] preview.
  final Uint8List? pendingBytes;

  final VoidCallback onPick;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasLogo = logoLocalPath != null || pendingBytes != null;

    Widget avatar;
    if (pendingBytes != null) {
      avatar = Image.memory(
        pendingBytes!,
        width: context.getRSize(80),
        height: context.getRSize(80),
        fit: BoxFit.cover,
      );
    } else if (logoLocalPath != null) {
      avatar = Image.file(
        File(logoLocalPath!),
        width: context.getRSize(80),
        height: context.getRSize(80),
        fit: BoxFit.cover,
      );
    } else {
      avatar = Icon(
        Icons.business_rounded,
        size: context.getRSize(40),
        color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
      );
    }

    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: context.getRSize(80),
            height: context.getRSize(80),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: theme.colorScheme.outline.withValues(alpha: 0.3),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: avatar,
            ),
          ),
        ),
        SizedBox(width: context.getRSize(16)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: onPick,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.getRSize(16),
                    vertical: context.getRSize(10),
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    hasLogo ? 'Change logo' : 'Upload logo',
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                      fontSize: context.getRFontSize(14),
                    ),
                  ),
                ),
              ),
              if (onRemove != null) ...[
                SizedBox(height: context.getRSize(8)),
                GestureDetector(
                  onTap: onRemove,
                  child: Text(
                    'Remove logo',
                    style: TextStyle(
                      color: theme.colorScheme.error,
                      fontSize: context.getRFontSize(13),
                    ),
                  ),
                ),
              ],
              SizedBox(height: context.getRSize(6)),
              Text(
                'PNG or JPG, max 512×512 px.',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  fontSize: context.getRFontSize(11),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────

class _PendingLogo {
  const _PendingLogo(this.bytes);
  final Uint8List bytes;
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
