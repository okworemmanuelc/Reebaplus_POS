import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// #783 — "Bring in old customer account": pick a customer, read what moving it
/// does, confirm. The money move is permanent (no undo in the app), so the
/// confirm step says so in plain words and shows the exact figures first.
Future<void> showBringInOldAccountFlow(
  BuildContext context,
  WidgetRef ref, {
  required VanDriverData driver,
}) async {
  final db = ref.read(databaseProvider);
  final userId = ref.read(authProvider).currentUser?.id;
  // Read straight from the database, not from a cached list: this page can be
  // the first place the customer list is needed in a session.
  final linked = await db.vanDriversDao.watchLinkedCustomerIds().first;
  final customers = [
    for (final c in await db.customersDao.watchAllCustomers().first)
      if (!linked.contains(c.id)) c,
  ];
  if (!context.mounted) return;

  final picked = await showDialog<CustomerData>(
    context: context,
    builder: (_) => _PickCustomerDialog(customers: customers),
  );
  if (picked == null || !context.mounted) return;

  final summary = await db.vanDriversDao.summariseOldAccount(picked.id);
  if (!context.mounted) return;

  final done = await showDialog<int>(
    context: context,
    builder: (_) => _ConfirmLinkDialog(
      driverName: driver.name,
      customerName: picked.name,
      summary: summary,
      onConfirm: () => db.vanDriversDao.linkOldCustomerAccount(
        vanDriverId: driver.id,
        customerId: picked.id,
        performedBy: userId,
      ),
    ),
  );
  if (done == null || !context.mounted) return;
  AppNotification.showSuccess(
    context,
    done > 0
        ? '${formatCurrency(done / 100)} moved to ${driver.name}.'
        : 'Old customer account brought in.',
  );
}

class _PickCustomerDialog extends StatefulWidget {
  final List<CustomerData> customers;
  const _PickCustomerDialog({required this.customers});

  @override
  State<_PickCustomerDialog> createState() => _PickCustomerDialogState();
}

class _PickCustomerDialogState extends State<_PickCustomerDialog> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final shown = [
      for (final c in widget.customers)
        if (q.isEmpty ||
            c.name.toLowerCase().contains(q) ||
            (c.phone ?? '').toLowerCase().contains(q))
          c,
    ];
    return AlertDialog(
      key: const Key('bring-in-pick-dialog'),
      title: const Text('Which old customer account?'),
      content: SizedBox(
        width: double.maxFinite,
        height: context.getRSize(380),
        child: Column(
          children: [
            TextField(
              key: const Key('bring-in-search'),
              decoration: const InputDecoration(
                hintText: 'Search customers...',
                prefixIcon: Icon(AppIcons.search),
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
            SizedBox(height: context.getRSize(8)),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('No customers to pick.'))
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final c = shown[i];
                        return ListTile(
                          key: Key('bring-in-customer-${c.id}'),
                          title: Text(toNameCase(c.name)),
                          subtitle: (c.phone ?? '').isEmpty
                              ? null
                              : Text(c.phone!),
                          onTap: () => Navigator.pop(context, c),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _ConfirmLinkDialog extends StatelessWidget {
  final String driverName;
  final String customerName;
  final OldAccountSummary summary;
  final Future<int> Function() onConfirm;

  const _ConfirmLinkDialog({
    required this.driverName,
    required this.customerName,
    required this.summary,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final owed = summary.owedKobo;
    final inCredit = summary.balanceKobo > 0;
    return AlertDialog(
      key: const Key('bring-in-confirm-dialog'),
      scrollable: true,
      title: const Text('Bring in old customer account'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            toNameCase(customerName),
            style: t.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: context.getRSize(8)),
          Text('Past sales: ${summary.salesCount}'),
          Text('Payments: ${summary.paymentsCount}'),
          Text(
            owed > 0
                ? 'Balance owed: ${formatCurrency(owed / 100)}'
                : inCredit
                ? 'The shop owes this customer '
                      '${formatCurrency(summary.balanceKobo / 100)}'
                : 'Balance owed: ${formatCurrency(0)}',
            key: const Key('bring-in-balance'),
          ),
          SizedBox(height: context.getRSize(12)),
          Text(
            owed > 0
                ? '${formatCurrency(owed / 100)} will move from this '
                      'customer account to ${toNameCase(driverName)} as '
                      'driver debt. The old sales and payments stay as they '
                      'are, and show on the driver\'s page.'
                : 'Only the link is made. No money moves. The old sales and '
                      'payments show on the driver\'s page.',
          ),
          SizedBox(height: context.getRSize(12)),
          Text(
            'This cannot be undone.',
            key: const Key('bring-in-cannot-undo'),
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: t.colorScheme.error,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        AppButton(
          key: const Key('bring-in-confirm'),
          text: 'Bring in account',
          isFullWidth: false,
          onAsyncPressed: () async {
            try {
              final moved = await onConfirm();
              if (context.mounted) Navigator.pop(context, moved);
            } on OldAccountLinkException catch (e) {
              if (context.mounted) {
                AppNotification.showError(context, e.message);
                Navigator.pop(context);
              }
            } catch (_) {
              // Anything else (e.g. a database refusal): the transaction has
              // rolled back, so nothing moved. Say so and close.
              if (context.mounted) {
                AppNotification.showError(
                  context,
                  'Could not bring in this account. Nothing was changed.',
                );
                Navigator.pop(context);
              }
            }
          },
        ),
      ],
    );
  }
}
