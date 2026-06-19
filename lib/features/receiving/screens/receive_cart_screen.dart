import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_checkout_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

class ReceiveCartScreen extends ConsumerWidget {
  const ReceiveCartScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(receiveCartProvider);
    final notifier = ref.read(receiveCartProvider.notifier);
    final bg = Theme.of(context).colorScheme.surface;
    final cardColor = Theme.of(context).cardColor;
    final textColor = Theme.of(context).colorScheme.onSurface;
    final primary = Theme.of(context).colorScheme.primary;

    final totalUnits = notifier.totalUnits;
    final totalValueKobo = notifier.invoiceTotalKobo;
    final totalValueStr = formatCurrency(totalValueKobo / 100);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: const Text('Receive Stock Cart'),
        elevation: 0,
        backgroundColor: bg,
        actions: [
          if (cart.isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Clear Cart'),
                    content: const Text('Are you sure you want to remove all items from the cart?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Clear', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                );
                
                if (confirm == true && context.mounted) {
                  notifier.clear();
                  Navigator.pop(context);
                }
              },
              icon: const Icon(Icons.delete_sweep, color: Colors.redAccent, size: 20),
              label: const Text('Clear', style: TextStyle(color: Colors.redAccent)),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: cart.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(FontAwesomeIcons.boxOpen.data, size: 64, color: Theme.of(context).dividerColor),
                  const SizedBox(height: 16),
                  Text(
                    'Your receive cart is empty',
                    style: TextStyle(color: textColor, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap products from the grid to add them.',
                    style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.only(top: 8, bottom: 100),
              itemCount: cart.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final line = cart[index];
                return Dismissible(
                  key: ValueKey(line.productId),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    color: Colors.red,
                    child: Icon(FontAwesomeIcons.trash.data, color: Colors.white, size: 20),
                  ),
                  onDismissed: (_) {
                    notifier.remove(line.productId);
                  },
                  child: Container(
                    color: cardColor,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Details
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                line.productName,
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: textColor),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${line.unit ?? 'Unit'} • ${formatCurrency(line.buyingPriceKobo / 100)} each',
                                style: TextStyle(fontSize: 13, color: Theme.of(context).textTheme.bodySmall?.color),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Total: ${formatCurrency(line.buyingPriceKobo * line.qty / 100)}',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: primary),
                              ),
                            ],
                          ),
                        ),
                        // Qty controls
                        Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: Theme.of(context).dividerColor),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(FontAwesomeIcons.minus.data, size: 14),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                                onPressed: () {
                                  notifier.setQty(line.productId, line.qty - 1);
                                },
                              ),
                              Container(
                                constraints: const BoxConstraints(minWidth: 30),
                                alignment: Alignment.center,
                                child: Text(
                                  '${line.qty}',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                              ),
                              IconButton(
                                icon: Icon(FontAwesomeIcons.plus.data, size: 14),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                                onPressed: () {
                                  notifier.setQty(line.productId, line.qty + 1);
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
      bottomSheet: cart.isEmpty
          ? null
          : Container(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + context.deviceBottomPadding),
              decoration: BoxDecoration(
                color: cardColor,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    offset: const Offset(0, -4),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Invoice Total:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      Text(
                        totalValueStr,
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: primary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  AppButton(
                    text: 'Continue ($totalUnits items)',
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ReceiveCheckoutScreen()),
                      );
                    },
                    isFullWidth: true,
                  ),
                ],
              ),
            ),
    );
  }
}
