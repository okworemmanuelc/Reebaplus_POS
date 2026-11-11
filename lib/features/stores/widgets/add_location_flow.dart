import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/stores/widgets/stores_parts.dart';
import 'package:reebaplus_pos/features/subscription/subscription_plan.dart';
import 'package:reebaplus_pos/features/subscription/subscription_plan_providers.dart';
import 'package:reebaplus_pos/features/subscription/widgets/plan_limit_widgets.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Register a new location — a store or a van — for the current business.
/// The single path behind Settings → Stores and the Van Sales hub (#779): the
/// gate, the plan-limit pre-check, the sheet, the [StoresDao.createStore]
/// insert and the activity-log action all live here so a van made in either
/// place is identical.
///
/// Returns true when a row was created. Shows its own success/error notices.
Future<bool> addLocationFlow(
  BuildContext context,
  WidgetRef ref, {
  required bool isVan,
}) async {
  // Write boundary (hard rule #6) — re-checked at fire time, not just render.
  final gate = isVan ? Gates.vanManage : Gates.manageStores;
  if (!gate.allowsNow(ref)) {
    showGateDenied(context, gate);
    return false;
  }
  // Plan limit pre-check (reebaplus-web#90). The server trigger is the
  // authority; this explains it up front instead of after a failed sync.
  final plan = ref.read(effectivePlanProvider);
  final limits = ref.read(planLimitsProvider);
  final usage = ref.read(planUsageProvider);
  final blocked = isVan
      ? checkAddVan(limits)
      : checkAddStore(limits, currentStores: usage.stores);
  if (blocked != null) {
    showPlanLimitNotice(context, blocked, plan: plan);
    return false;
  }
  // The sheet owns its controllers and hands the values back through `pop`.
  final created = await showStoresSheet<NewLocation>(
    context,
    (_) => AddLocationSheet(isVan: isVan),
  );
  // A non-null result means the sheet's validator passed.
  if (created == null) return false;

  final db = ref.read(databaseProvider);
  try {
    await db.storesDao.createStore(
      name: created.name,
      location: created.note,
      kind: isVan ? kStoreKindVan : kStoreKindStore,
    );
    await db.activityLogDao.log(
      action: isVan ? 'settings.van.create' : 'settings.store.create',
      description: isVan
          ? 'Registered van "${created.name}"'
          : 'Added store "${created.name}"',
      staffId: db.currentUserId,
    );
    if (!context.mounted) return true;
    AppNotification.showSuccess(
      context,
      isVan ? 'Van added.' : 'Store added.',
    );
    return true;
  } catch (e) {
    if (!context.mounted) return false;
    final limit = planLimitKindOf(e);
    if (limit != null) {
      showPlanLimitNotice(context, limit, plan: plan);
      return false;
    }
    AppNotification.showError(
      context,
      isVan ? "Couldn't add the van." : "Couldn't add the store.",
    );
    return false;
  }
}

/// What an add-location sheet hands back: a name plus the optional second line
/// that lands in the `location` column. Returned through `Navigator.pop` rather
/// than read off caller-owned controllers — that indirection is what lets the
/// sheet own its own fields (see [AddLocationSheet]).
class NewLocation {
  const NewLocation({required this.name, required this.note});

  /// Non-empty — the sheet only pops once its validator has passed.
  final String name;

  /// A store's address or a van's plate/route. May be empty; `createStore`
  /// stores empty as NULL.
  final String note;
}

/// The "Add a store" / "Add a van" bottom sheet — a name (required) plus an
/// optional second line stored in the same `location` column (a store's
/// address; a van's plate number or route). The two differ only in wording and
/// icon, because a van *is* a `stores` row.
///
/// **Owns its controllers.** They are created and disposed inside this State so
/// they can never be disposed out from under the fields reading them (the
/// earlier version took them from the caller, which disposed them while the
/// sheet was still animating out). Hence [NewLocation] as the result.
class AddLocationSheet extends StatefulWidget {
  const AddLocationSheet({super.key, required this.isVan});

  final bool isVan;

  @override
  State<AddLocationSheet> createState() => AddLocationSheetState();
}

class AddLocationSheetState extends State<AddLocationSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _noteController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      NewLocation(
        name: toNameCase(_nameController.text),
        note: _noteController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isVan = widget.isVan;
    // The frame adds deviceBottomPadding (nav only), never deviceBottomInset:
    // the sheet sits under MainLayout's Scaffold, which already resizes for
    // the keyboard.
    return Form(
      key: _formKey,
      child: StoreSheetFrame(
        icon: isVan ? AppIcons.supplier : AppIcons.store,
        title: isVan ? 'Add a van' : 'Add a store',
        subtitle: isVan
            ? 'Give it a name your drivers will recognise.'
            : 'Give it a name your staff will recognise.',
        children: [
          AppInput(
            controller: _nameController,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            labelText: isVan ? 'Van name' : 'Store name',
            prefixIcon: Icon(
              isVan ? AppIcons.supplier : AppIcons.store,
              size: 20,
            ),
            validator: (v) => (v == null || v.trim().isEmpty)
                ? (isVan ? 'Give the van a name' : 'Give the store a name')
                : null,
          ),
          SizedBox(height: context.getRSize(12)),
          AppInput(
            controller: _noteController,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _submit(),
            labelText: isVan
                ? 'Plate number or route (optional)'
                : 'Address (optional)',
            prefixIcon: const Icon(AppIcons.location, size: 20),
          ),
          SizedBox(height: context.getRSize(24)),
          AppButton(text: isVan ? 'Add van' : 'Add store', onPressed: _submit),
        ],
      ),
    );
  }
}
