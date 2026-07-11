import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_checkout_screen.dart';
import 'package:reebaplus_pos/features/receiving/widgets/edit_receive_item_modal.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

class ReceiveCartScreen extends ConsumerWidget {
  const ReceiveCartScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(receiveCartProvider);
    final notifier = ref.read(receiveCartProvider.notifier);
    final t = Theme.of(context);
    final bg = t.colorScheme.surface;
    final text = t.colorScheme.onSurface;
    final primary = t.colorScheme.primary;
    final border = t.dividerColor;

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
                    content: const Text(
                      'Are you sure you want to remove all items from the cart?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(
                          'Clear',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                );

                if (confirm == true && context.mounted) {
                  notifier.clear();
                  Navigator.pop(context);
                }
              },
              icon: Icon(
                FontAwesomeIcons.trashCan.data,
                color: Theme.of(context).colorScheme.error,
                size: context.getRSize(16),
              ),
              label: Text(
                'Clear',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          SizedBox(width: context.getRSize(8)),
        ],
      ),
      body: cart.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: EdgeInsets.all(context.getRSize(24)),
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      FontAwesomeIcons.boxOpen.data,
                      size: context.getRSize(48),
                      color: primary.withValues(alpha: 0.6),
                    ),
                  ),
                  SizedBox(height: context.getRSize(24)),
                  Text(
                    'Your receive cart is empty',
                    style: TextStyle(
                      color: text,
                      fontSize: context.getRFontSize(18),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: context.getRSize(8)),
                  Text(
                    'Tap products from the grid to add them.',
                    style: TextStyle(
                      color: text.withValues(alpha: 0.6),
                      fontSize: context.getRFontSize(14),
                    ),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: EdgeInsets.only(
                top: context.getRSize(16),
                bottom: context.getRSize(24),
                left: context.getRSize(16),
                right: context.getRSize(16),
              ),
              itemCount: cart.length,
              separatorBuilder: (_, __) =>
                  SizedBox(height: context.getRSize(12)),
              itemBuilder: (context, index) {
                final line = cart[index];
                return Dismissible(
                  key: ValueKey(line.productId),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: EdgeInsets.only(right: context.getRSize(20)),
                    decoration: BoxDecoration(
                      color: t.colorScheme.error,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      FontAwesomeIcons.trash.data,
                      color: t.colorScheme.onError,
                      size: context.getRSize(20),
                    ),
                  ),
                  onDismissed: (_) {
                    notifier.remove(line.productId);
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: t.cardColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: border.withValues(alpha: 0.5)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.02),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          EditReceiveItemModal.show(context, line);
                        },
                        borderRadius: BorderRadius.circular(16),
                        child: Padding(
                          padding: EdgeInsets.all(context.getRSize(16)),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // Left: Qty chip
                              Container(
                                width: context.getRSize(44),
                                height: context.getRSize(44),
                                decoration: BoxDecoration(
                                  color: bg,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: border.withValues(alpha: 0.5),
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  line.qty.toString(),
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: context.getRFontSize(16),
                                    color: text,
                                  ),
                                ),
                              ),
                              SizedBox(width: context.getRSize(16)),
                              // Middle: details
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      line.productName,
                                      style: TextStyle(
                                        fontSize: context.getRFontSize(16),
                                        fontWeight: FontWeight.bold,
                                        color: text,
                                      ),
                                    ),
                                    SizedBox(height: context.getRSize(4)),
                                    Row(
                                      children: [
                                        // A unitless product (#108) shows no
                                        // unit label — just its cost.
                                        if ((line.unit ?? '').isNotEmpty) ...[
                                          Text(
                                            line.unit!,
                                            style: TextStyle(
                                              fontSize:
                                                  context.getRFontSize(13),
                                              color:
                                                  text.withValues(alpha: 0.6),
                                            ),
                                          ),
                                          SizedBox(width: context.getRSize(8)),
                                        ],
                                        Flexible(
                                          child: Container(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: context.getRSize(6),
                                              vertical: context.getRSize(2),
                                            ),
                                            decoration: BoxDecoration(
                                              color: primary.withValues(
                                                alpha: 0.1,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              'Cost: ${formatCurrency(line.buyingPriceKobo / 100)}',
                                              overflow: TextOverflow.ellipsis,
                                              maxLines: 1,
                                              style: TextStyle(
                                                fontSize:
                                                    context.getRFontSize(11),
                                                fontWeight: FontWeight.w600,
                                                color: primary,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: context.getRSize(6)),
                                    Text(
                                      'Ret: ${formatCurrency(line.retailKobo / 100)} • Whls: ${formatCurrency(line.wholesaleKobo / 100)}',
                                      style: TextStyle(
                                        fontSize: context.getRFontSize(12),
                                        color: text.withValues(alpha: 0.5),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(width: context.getRSize(12)),
                              // Right: Total
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    formatCurrency(
                                      line.buyingPriceKobo * line.qty / 100,
                                    ),
                                    style: TextStyle(
                                      fontSize: context.getRFontSize(16),
                                      fontWeight: FontWeight.w800,
                                      color: primary,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
      bottomNavigationBar: cart.isEmpty
          ? null
          : Container(
              padding: EdgeInsets.fromLTRB(
                context.getRSize(24),
                context.getRSize(20),
                context.getRSize(24),
                context.getRSize(20) + context.deviceBottomPadding,
              ),
              decoration: BoxDecoration(
                color: t.colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(32),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    offset: const Offset(0, -8),
                    blurRadius: 24,
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
                      Text(
                        'Invoice Total:',
                        style: TextStyle(
                          fontSize: context.getRFontSize(16),
                          fontWeight: FontWeight.w600,
                          color: text.withValues(alpha: 0.6),
                        ),
                      ),
                      Text(
                        totalValueStr,
                        style: TextStyle(
                          fontSize: context.getRFontSize(24),
                          fontWeight: FontWeight.w900,
                          color: primary,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: context.getRSize(20)),
                  AppButton(
                    text: 'Continue ($totalUnits items)',
                    height: context.getRSize(56),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const ReceiveCheckoutScreen(),
                        ),
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
