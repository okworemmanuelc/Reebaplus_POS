import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/data/area_selection.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/result.dart';
import 'package:reebaplus_pos/core/services/store_online_service.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/stores/widgets/stores_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/area_picker.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// "Ikeja, Lagos" / "All of Lagos" for one delivery area or store area.
String describeArea({required String state, String? lga}) =>
    (lga ?? '').trim().isEmpty ? 'All of $state' : '$lga, $state';

/// One store's online page (#423): its own area, the Online ordering switch,
/// delivery areas and the public phone + shopper note. Reached from
/// Settings → Online store and from Store Details. Every write re-checks
/// [Gates.manageOnlineStore] through [StoreOnlineService].
class OnlineStoreDetailScreen extends ConsumerStatefulWidget {
  const OnlineStoreDetailScreen({super.key, required this.storeId});

  final String storeId;

  @override
  ConsumerState<OnlineStoreDetailScreen> createState() =>
      _OnlineStoreDetailScreenState();
}

class _OnlineStoreDetailScreenState extends ConsumerState<OnlineStoreDetailScreen> {
  StoreData? _store;
  List<StoreDeliveryAreaData> _areas = const [];
  bool _loaded = false;
  bool _busy = false;
  final _phone = TextEditingController();
  final _note = TextEditingController();
  StreamSubscription<StoreData?>? _storeSub;
  StreamSubscription<List<StoreDeliveryAreaData>>? _areasSub;

  @override
  void initState() {
    super.initState();
    final dao = ref.read(databaseProvider).storesDao;
    _storeSub = dao.watchStore(widget.storeId).listen((store) {
      if (!mounted) return;
      final first = _store == null && store != null;
      setState(() {
        _store = store;
        _loaded = true;
      });
      // Seed the text boxes once; a later sync never overwrites typing.
      if (first) {
        _phone.text = store.phone ?? '';
        _note.text = store.onlineNote ?? '';
      }
    });
    _areasSub = dao.watchDeliveryAreas(widget.storeId).listen((areas) {
      if (mounted) setState(() => _areas = areas);
    });
  }

  @override
  void dispose() {
    _storeSub?.cancel();
    _areasSub?.cancel();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  StoreOnlineService get _service =>
      StoreOnlineService(ref.read(databaseProvider).storesDao);

  Future<void> _write(
    Future<Result<void, AppError>> Function(StoreOnlineService s) call, {
    String? success,
  }) async {
    if (!Gates.manageOnlineStore.allowsNow(ref)) {
      showGateDenied(context, Gates.manageOnlineStore);
      return;
    }
    setState(() => _busy = true);
    final result = await call(_service);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result) {
      case Ok():
        if (success != null) AppNotification.showSuccess(context, success);
      case Err(:final error):
        AppNotification.showError(context, error.message);
    }
  }

  Future<void> _pickStoreArea(StoreData store) async {
    final area = await showAreaPicker(
      context,
      initialValue: (store.state ?? '').isEmpty
          ? null
          : AreaSelection(
              country: store.country ?? 'Nigeria', state: store.state!, lga: store.lga),
    );
    if (area == null || !mounted) return;
    await _write((s) => s.setArea(
      storeId: store.id, area: area, gateContext: ref.read(gateContextProvider)));
  }

  Future<void> _addDeliveryArea(StoreData store) async {
    final area = await showAreaPicker(
      context,
      allowWholeState: true,
      initialValue: (store.state ?? '').isEmpty
          ? null
          : AreaSelection(country: store.country ?? 'Nigeria', state: store.state!),
    );
    if (area == null || !mounted) return;
    await _write((s) => s.addDeliveryArea(
      storeId: store.id, area: area, gateContext: ref.read(gateContextProvider)));
  }

  @override
  Widget build(BuildContext context) {
    final canManage = Gates.manageOnlineStore.allows(ref);
    final store = _store;
    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: StoresTopBar(
          height: storesTopBarHeight(context),
          header: ScreenHeader(
            leading: StoresBackButton(onPressed: () => Navigator.maybePop(context)),
            icon: AppIcons.public,
            title: store?.name ?? 'Online store',
            subtitle: 'Online store',
          ),
        ),
        body: !canManage
            ? const StoresMessage(
                key: Key('online-store-no-access'),
                text: 'You don\'t have access to the online store settings.',
              )
            : !_loaded
                ? const SizedBox.shrink()
                : store == null || store.isDeleted
                    ? const StoresMessage(text: 'This store is no longer available.')
                    : store.kind != kStoreKindStore
                        ? const StoresMessage(
                            key: Key('online-store-van'),
                            text: 'Vans cannot take online orders.',
                          )
                        : _body(context, store),
      ),
    );
  }

  Widget _body(BuildContext context, StoreData store) {
    final hasArea =
        (store.state ?? '').trim().isNotEmpty && (store.lga ?? '').trim().isNotEmpty;
    final blocker = !hasArea
        ? 'Set the store\'s state and local government area before switching '
            'online ordering on.'
        : _areas.isEmpty
            ? 'Add at least one delivery area before switching online ordering on.'
            : null;
    final gap = SizedBox(height: context.getRSize(16));
    return CustomScrollView(
      key: const Key('online-store-detail'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        storesSliver(
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _OnlineSwitchCard(
                  online: store.onlineOrderingEnabled,
                  blocker: store.onlineOrderingEnabled ? null : blocker,
                  busy: _busy,
                  onChanged: (v) => _write(
                    (s) => s.setOnlineOrdering(
                      storeId: store.id,
                      enabled: v,
                      gateContext: ref.read(gateContextProvider),
                    ),
                    success: v ? 'Online ordering is on.' : 'Online ordering is off.',
                  ),
                ),
                gap,
                const SectionHeader(title: 'Store area'),
                SizedBox(height: context.getRSize(8)),
                SettingsRow(
                  key: const Key('online-store-area'),
                  icon: AppIcons.location,
                  tone: hasArea ? IconTileTone.green : IconTileTone.warning,
                  title: hasArea
                      ? describeArea(state: store.state!, lga: store.lga)
                      : 'Set state and local government area',
                  subtitle: hasArea ? store.country ?? 'Nigeria' : 'Shoppers find stores by area',
                  onTap: _busy ? () {} : () => _pickStoreArea(store),
                ),
                gap,
                const SectionHeader(title: 'Delivery areas'),
                SizedBox(height: context.getRSize(8)),
                if (_areas.isEmpty)
                  Padding(
                    padding: EdgeInsets.only(bottom: context.getRSize(8)),
                    child: Text(
                      'No delivery areas yet. A whole state covers all its local '
                      'government areas.',
                      style: context.regularStyle(13),
                    ),
                  ),
                for (final area in _areas)
                  _DeliveryAreaTile(
                    key: ValueKey('delivery-area-${area.id}'),
                    label: describeArea(state: area.state, lga: area.lga),
                    onRemove: _busy
                        ? null
                        : () => _write((s) => s.removeDeliveryArea(
                              storeId: store.id,
                              areaId: area.id,
                              gateContext: ref.read(gateContextProvider),
                            )),
                  ),
                SizedBox(height: context.getRSize(8)),
                AppButton(
                  key: const Key('online-store-add-area'),
                  text: 'Add delivery area',
                  icon: AppIcons.add,
                  variant: AppButtonVariant.outline,
                  height: kMinInteractiveDimension,
                  onPressed: _busy ? null : () => _addDeliveryArea(store),
                ),
                gap,
                const SectionHeader(title: 'Shopper details'),
                SizedBox(height: context.getRSize(8)),
                AppInput(
                  key: const Key('online-store-phone'),
                  controller: _phone,
                  labelText: 'Store phone',
                  hintText: 'Uses the business phone when empty',
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.next,
                  prefixIcon: const Icon(AppIcons.phone, size: 20),
                ),
                SizedBox(height: context.getRSize(12)),
                AppInput(
                  key: const Key('online-store-note'),
                  controller: _note,
                  labelText: 'Note for shoppers',
                  hintText: 'Delivery fee, pickup and delivery days',
                  minLines: 2,
                  maxLines: 4,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(kStoreOnlineNoteMaxLength),
                  ],
                  onChanged: (_) => setState(() {}),
                ),
                Padding(
                  padding: EdgeInsets.only(top: context.getRSize(4)),
                  child: Text(
                    '${_note.text.length}/$kStoreOnlineNoteMaxLength',
                    textAlign: TextAlign.end,
                    style: context.regularStyle(12),
                  ),
                ),
                SizedBox(height: context.getRSize(12)),
                AppButton(
                  key: const Key('online-store-save-details'),
                  text: 'Save details',
                  onPressed: _busy
                      ? null
                      : () => _write(
                            (s) => s.setContact(
                              storeId: store.id,
                              phone: _phone.text,
                              onlineNote: _note.text,
                              gateContext: ref.read(gateContextProvider),
                            ),
                            success: 'Details saved.',
                          ),
                ),
              ],
            ),
          ),
          top: context.getRSize(16),
          bottom: context.getRSize(24) + context.deviceBottomPadding,
        ),
      ],
    );
  }
}

/// The Online ordering switch, disabled with a clear prompt until the store
/// can go online.
class _OnlineSwitchCard extends StatelessWidget {
  const _OnlineSwitchCard({
    required this.online,
    required this.blocker,
    required this.busy,
    required this.onChanged,
  });

  final bool online;
  final String? blocker;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              key: const Key('online-store-switch'),
              contentPadding: EdgeInsets.zero,
              title: Text('Online ordering',
                  style: context.boldStyle(15).copyWith(color: t.colorScheme.onSurface)),
              subtitle: Text(
                online
                    ? 'Shoppers in your delivery areas can order from this store.'
                    : 'Hidden from shoppers.',
                style: context.regularStyle(12).copyWith(color: muted),
              ),
              value: online,
              onChanged: busy || blocker != null ? null : onChanged,
            ),
            if (blocker != null) ...[
              SizedBox(height: context.getRSize(8)),
              StoresNotice(
                key: const Key('online-store-blocker'),
                tone: IconTileTone.warning,
                icon: AppIcons.warning,
                text: blocker!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DeliveryAreaTile extends StatelessWidget {
  const _DeliveryAreaTile({super.key, required this.label, required this.onRemove});

  final String label;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(8)),
      child: DecoratedBox(
        decoration: AppDecorations.card(context),
        child: ListTile(
          minTileHeight: kMinInteractiveDimension,
          leading: const Icon(AppIcons.map),
          title: Text(label,
              style: context.regularStyle(14).copyWith(color: t.colorScheme.onSurface)),
          trailing: IconButton(
            tooltip: 'Remove $label',
            icon: const Icon(AppIcons.removeCircle),
            onPressed: onRemove,
          ),
        ),
      ),
    );
  }
}
