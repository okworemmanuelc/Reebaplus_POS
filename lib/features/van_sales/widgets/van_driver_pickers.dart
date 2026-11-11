import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// "Add a driver" (#748): a name and an optional phone. No invite, no sign-in,
/// not a customer. Returns the new driver, or null when cancelled.
Future<VanDriverData?> showAddVanDriverDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final name = TextEditingController();
  final phone = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: const Text('Add a driver'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Phone (optional)'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Add'),
        ),
      ],
    ),
  );
  final typed = name.text.trim();
  final typedPhone = phone.text;
  name.dispose();
  phone.dispose();
  if (ok != true || typed.isEmpty) return null;
  final dao = ref.read(databaseProvider).vanDriversDao;
  final id = await dao.addDriver(name: typed, phone: typedPhone);
  return dao.getDriver(id);
}

/// Pick a driver for a trip, or "No driver assigned" (#748). Moving a trip to a
/// driver moves what that trip owes to them; no amount is edited.
Future<void> showAssignTripDriverSheet(
  BuildContext context,
  WidgetRef ref,
  VanTripData trip,
) async {
  final picked = await _pickDriver(
    context,
    ref,
    title: 'Who answers for this trip?',
    currentId: trip.vanDriverId,
    allowNone: true,
  );
  if (picked == null) return; // dismissed
  try {
    await ref
        .read(databaseProvider)
        .vanTripsDao
        .assignTripDriver(trip.id, picked.id);
  } on VanTripAlreadyOpenException catch (e) {
    if (context.mounted) AppNotification.showError(context, e.message);
  }
}

/// Pick the driver a van normally has (pre-fills its next load), or none.
Future<void> showAssignVanDriverSheet(
  BuildContext context,
  WidgetRef ref,
  String vanStoreId,
) async {
  final current = ref.read(storeByIdProvider(vanStoreId)).valueOrNull;
  final picked = await _pickDriver(
    context,
    ref,
    title: 'Who usually drives this van?',
    currentId: current?.vanDriverId,
    allowNone: true,
  );
  if (picked == null) return;
  await ref
      .read(databaseProvider)
      .vanDriversDao
      .assignToVan(vanStoreId, picked.id);
}

/// A pick result: [id] null means "No driver assigned".
class _Pick {
  final String? id;
  const _Pick(this.id);
}

Future<_Pick?> _pickDriver(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required String? currentId,
  required bool allowNone,
}) {
  return showModalBottomSheet<_Pick>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Consumer(
      builder: (ctx, ref, _) {
        final drivers = ref.watch(vanDriversProvider);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: ctx.getRHeight(0.7),
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Text(
                    title,
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (allowNone)
                  ListTile(
                    title: const Text('No driver assigned'),
                    trailing: currentId == null
                        ? const Icon(AppIcons.check)
                        : null,
                    onTap: () => Navigator.pop(ctx, const _Pick(null)),
                  ),
                for (final d in drivers)
                  ListTile(
                    title: Text(d.name),
                    subtitle: (d.phone ?? '').isEmpty ? null : Text(d.phone!),
                    trailing: d.id == currentId
                        ? const Icon(AppIcons.check)
                        : null,
                    onTap: () => Navigator.pop(ctx, _Pick(d.id)),
                  ),
                ListTile(
                  leading: const Icon(AppIcons.add),
                  title: const Text('Add a new driver'),
                  onTap: () async {
                    final created = await showAddVanDriverDialog(ctx, ref);
                    if (created != null && ctx.mounted) {
                      Navigator.pop(ctx, _Pick(created.id));
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
