import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/data/business_types.dart';
import 'package:reebaplus_pos/core/data/currencies.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/result.dart';
import 'package:reebaplus_pos/core/settings/settings_page_parts.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/settings/vat_settings.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

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
  // VAT basis (#176): inclusive = marked prices already contain VAT (the
  // default, most shops); exclusive = VAT added on top. Inclusive avoids the
  // (1+r) overstatement the exclusive formula produced for inclusive-price shops.
  VatBasis _vatBasis = VatBasis.inclusive;
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
    final vatBasis = parseVatBasis(await db.settingsDao.get(kVatBasisKey));

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
      _vatBasis = vatBasis;
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
        // #176 — persist the inclusive/exclusive basis (inclusive default).
        await db.settingsDao.set(
          kVatBasisKey,
          _vatBasis == VatBasis.inclusive ? 'inclusive' : 'exclusive',
        );
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
    // Offer only the selectable trades (#112). If this tenant is already on a
    // now-hidden trade, keep its current type visible + selected (grandfathered)
    // so opening this screen can never blank or silently change their industry —
    // switching still offers only the three.
    final typeOptions = <String>[
      ...kSelectableBusinessTypes,
      if (_type != null && !kSelectableBusinessTypes.contains(_type)) _type!,
    ];
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final above = SizedBox(height: context.getRSize(16));
    final below = SizedBox(height: context.getRSize(10));
    final gap = SizedBox(height: context.getRSize(16));
    return SettingsPageScaffold(
      icon: AppIcons.business,
      title: 'Business Info',
      body: !canManage
          ? const SettingsNoAccess()
          : _loading
          ? const SizedBox.shrink()
          : SettingsFadeIn(
              child: SettingsPageList(
                listKey: const Key('business-info-list'),
                children: [
                  const SectionHeader(
                    title: 'Logo',
                    variant: SectionHeaderVariant.group,
                  ),
                  below,
                  SettingsCard(
                    child: _LogoSection(
                      logoLocalPath: _pendingLogo != null || _pendingRemoveLogo
                          ? null
                          : _logoLocalPath,
                      pendingBytes: _pendingLogo?.bytes,
                      onPick: _pickLogo,
                      onRemove: _logoLocalPath != null || _pendingLogo != null
                          ? _removeLogo
                          : null,
                    ),
                  ),
                  above,
                  const SectionHeader(
                    title: 'Business',
                    variant: SectionHeaderVariant.group,
                  ),
                  below,
                  SettingsCard(
                    child: Column(
                      children: [
                        AppInput(
                          controller: _nameController,
                          textCapitalization: TextCapitalization.words,
                          labelText: 'Business name',
                          prefixIcon: Icon(AppIcons.business, color: muted),
                        ),
                        gap,
                        AppInput(
                          controller: _phoneController,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          labelText: 'Phone number',
                          prefixIcon: Icon(AppIcons.phone, color: muted),
                        ),
                        gap,
                        AppDropdown<String>(
                          value: _type,
                          isExpanded: true,
                          labelText: 'Business type',
                          prefixIcon: Icon(AppIcons.category, color: muted),
                          items: [
                            for (final type in typeOptions)
                              DropdownMenuItem(value: type, child: Text(type)),
                          ],
                          onChanged: (v) => setState(() {
                            _type = v;
                            // Reset to default when type changes.
                            _tracksEmptyCrates = true;
                          }),
                        ),
                        if (isCrateBusiness(_type)) ...[
                          SizedBox(height: context.getRSize(8)),
                          _SwitchRow(
                            value: _tracksEmptyCrates,
                            onChanged: (v) =>
                                setState(() => _tracksEmptyCrates = v),
                            title: 'Track empty crates',
                            subtitle:
                                'Enable to track returnable bottles and crate deposits.',
                          ),
                        ],
                        gap,
                        AppDropdown<String>(
                          value: _currency,
                          isExpanded: true,
                          labelText: 'Currency',
                          prefixIcon: Icon(AppIcons.payments, color: muted),
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
                  above,
                  const SectionHeader(
                    title: 'Tax',
                    variant: SectionHeaderVariant.group,
                  ),
                  below,
                  SettingsCard(
                    child: Column(
                      children: [
                        _SwitchRow(
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
                          title: 'Charge VAT',
                          subtitle:
                              'Only enable if your business is registered to '
                              'charge VAT. It appears on the daily closing.',
                        ),
                        if (_vatEnabled) ...[
                          SizedBox(height: context.getRSize(8)),
                          AppInput(
                            controller: _vatRateController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'^\d*\.?\d*'),
                              ),
                            ],
                            labelText: 'VAT rate (%)',
                            prefixIcon: Icon(AppIcons.divide, color: muted),
                          ),
                          // #176 — inclusive/exclusive basis (inclusive default).
                          SizedBox(height: context.getRSize(8)),
                          _SwitchRow(
                            value: _vatBasis == VatBasis.inclusive,
                            onChanged: (v) => setState(() {
                              _vatBasis = v
                                  ? VatBasis.inclusive
                                  : VatBasis.exclusive;
                            }),
                            title: 'Prices already include VAT',
                            subtitle:
                                'On: your marked prices contain VAT (most shops), '
                                'so the closing shows the VAT portion within them. '
                                'Off: VAT is added on top of your prices.',
                          ),
                        ],
                      ],
                    ),
                  ),
                  above,
                  AppButton(
                    text: 'Save changes',
                    onPressed: _saving ? null : _save,
                  ),
                ],
              ),
            ),
    );
  }
}

/// A switch row inside a settings card: Bold 15 title, Regular 13 muted
/// subtitle, the primary-coloured [Switch] on the right (48dp tall at least).
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.value,
    required this.onChanged,
    required this.title,
    required this.subtitle,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      activeThumbColor: t.colorScheme.primary,
      activeTrackColor: t.colorScheme.primary.withValues(alpha: 0.35),
      title: Text(
        title,
        style: context.boldStyle(15).copyWith(color: t.colorScheme.onSurface),
      ),
      subtitle: Text(
        subtitle,
        style: context.regularStyle(13).copyWith(color: muted),
      ),
      contentPadding: EdgeInsets.zero,
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
    final muted =
        theme.textTheme.bodySmall?.color ?? theme.colorScheme.onSurface;
    final hasLogo = logoLocalPath != null || pendingBytes != null;
    final edge = context.getRSize(80);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);

    Widget avatar;
    if (pendingBytes != null) {
      avatar = Image.memory(
        pendingBytes!,
        width: edge,
        height: edge,
        fit: BoxFit.cover,
      );
    } else if (logoLocalPath != null) {
      avatar = Image.file(
        File(logoLocalPath!),
        width: edge,
        height: edge,
        fit: BoxFit.cover,
      );
    } else {
      avatar = Icon(
        AppIcons.business,
        size: context.getRSize(40),
        color: muted,
      );
    }

    return Row(
      children: [
        Container(
          width: edge,
          height: edge,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: radius,
            border: Border.all(color: theme.dividerColor),
          ),
          child: ClipRRect(borderRadius: radius, child: Center(child: avatar)),
        ),
        SizedBox(width: context.getRSize(16)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppButton(
                text: hasLogo ? 'Change logo' : 'Upload logo',
                variant: AppButtonVariant.outline,
                size: AppButtonSize.small,
                isFullWidth: false,
                onPressed: onPick,
              ),
              if (onRemove != null) ...[
                SizedBox(height: context.getRSize(4)),
                TextButton(
                  onPressed: onRemove,
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    minimumSize: const Size(0, kMinInteractiveDimension),
                    padding: EdgeInsets.zero,
                    alignment: Alignment.centerLeft,
                  ),
                  child: Text(
                    'Remove logo',
                    style: context.semiBoldStyle(13),
                  ),
                ),
              ],
              SizedBox(height: context.getRSize(4)),
              Text(
                'PNG or JPG, max 512×512 px.',
                style: context.regularStyle(12).copyWith(color: muted),
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
