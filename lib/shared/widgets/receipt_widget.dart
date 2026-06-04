import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/product_name.dart';
import 'package:reebaplus_pos/core/utils/stock_calculator.dart';

class ReceiptWidget extends StatelessWidget {
  final String orderId;
  final List<Map<String, dynamic>> cart;
  final double subtotal;
  final double crateDeposit;
  final double total;
  final String paymentMethod;
  final String? customerName;
  final String? customerAddress;
  final String? customerPhone;
  final double? cashReceived;
  final double? walletBalance;

  /// §15.1 — wallet info is printed only when the cashier ticked the
  /// "Add wallet info to receipt" checkbox at checkout. Off by default.
  final bool showWalletInfo;
  final DateTime? reprintDate;
  final DateTime? reshareDate;
  final String? riderName;
  final String? deliveryRef;
  final String? orderStatus;
  final double? refundAmount;

  /// manufacturerId → name — used to label crate deposit rows by manufacturer.
  final Map<String, String>? manufacturerNames;

  /// Name of the store / branch that processed this sale.
  final String? branchName;

  /// The business name (§15.1) — shown as the receipt header. Read live from
  /// the `businesses` row so a rename in Business Info (§10.1) reflects here.
  final String? businessName;

  const ReceiptWidget({
    super.key,
    required this.orderId,
    required this.cart,
    required this.subtotal,
    required this.crateDeposit,
    required this.total,
    required this.paymentMethod,
    this.customerName,
    this.customerAddress,
    this.customerPhone,
    this.cashReceived,
    this.walletBalance,
    this.showWalletInfo = false,
    this.reprintDate,
    this.reshareDate,
    this.riderName,
    this.deliveryRef,
    this.orderStatus,
    this.refundAmount,
    this.manufacturerNames,
    this.branchName,
    this.businessName,
  });

  @override
  Widget build(BuildContext context) {
    // Receipts always use black-on-white regardless of app theme.
    const bg = Colors.white;
    const textCol = Color(0xFF111111);
    const sub = Color(0xFF555555);
    const divCol = Color(0xFFDDDDDD);
    const primary = Color(0xFFF5A623); // amberPrimary brand colour

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(24)),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: divCol),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (reprintDate != null) ...[
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.getRSize(12),
                vertical: context.getRSize(4),
              ),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                border: Border.all(color: Colors.red.withValues(alpha: 0.5)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'REPRINTED',
                style: TextStyle(
                  fontSize: context.getRFontSize(16),
                  fontWeight: FontWeight.w900,
                  color: Colors.red,
                  letterSpacing: 2,
                ),
              ),
            ),
            SizedBox(height: context.getRSize(12)),
          ],
          if (reshareDate != null) ...[
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.getRSize(12),
                vertical: context.getRSize(4),
              ),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                border: Border.all(color: Colors.red.withValues(alpha: 0.5)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'RESHARED',
                style: TextStyle(
                  fontSize: context.getRFontSize(16),
                  fontWeight: FontWeight.w900,
                  color: Colors.red,
                  letterSpacing: 2,
                ),
              ),
            ),
            SizedBox(height: context.getRSize(12)),
          ],
          if (orderStatus == 'Refunded') ...[
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.getRSize(12),
                vertical: context.getRSize(4),
              ),
              decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.1),
                border: Border.all(color: primary.withValues(alpha: 0.5)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'REFUNDED ${formatCurrency(refundAmount ?? total)}',
                style: TextStyle(
                  fontSize: context.getRFontSize(14),
                  fontWeight: FontWeight.w900,
                  color: primary,
                  letterSpacing: 1,
                ),
              ),
            ),
            SizedBox(height: context.getRSize(12)),
          ],
          if (businessName != null && businessName!.trim().isNotEmpty)
            Text(
              businessName!.trim(),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.getRFontSize(20),
                fontWeight: FontWeight.w800,
                color: textCol,
              ),
            ),
          if (branchName != null && branchName!.isNotEmpty) ...[
            Text(
              'Branch: $branchName',
              style: TextStyle(fontSize: context.getRFontSize(12), color: sub),
            ),
          ],
          Text(
            deliveryRef != null ? 'Delivery Receipt' : 'Sales Receipt',
            style: TextStyle(fontSize: context.getRFontSize(12), color: sub),
          ),
          if (deliveryRef != null) ...[
            SizedBox(height: context.getRSize(4)),
            Text(
              'Ref: $deliveryRef',
              style: TextStyle(
                fontSize: context.getRFontSize(13),
                fontWeight: FontWeight.bold,
                color: primary,
              ),
            ),
          ],
          SizedBox(height: context.getRSize(16)),
          Container(height: 1, color: divCol),
          SizedBox(height: context.getRSize(12)),

          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              (customerName != null && customerName!.isNotEmpty)
                  ? [
                      customerName!,
                      if (customerAddress != null &&
                          customerAddress!.isNotEmpty)
                        customerAddress!,
                      if (customerPhone != null && customerPhone!.isNotEmpty)
                        customerPhone!,
                    ].join('\n')
                  : 'Walk-in Customer',
              style: TextStyle(
                fontSize: context.getRFontSize(13),
                fontWeight: FontWeight.bold,
                color: textCol,
              ),
            ),
          ),
          SizedBox(height: context.getRSize(8)),
          Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Order: #$orderId',
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    color: sub,
                  ),
                ),
                Text(
                  'Date: ${_formatDate(DateTime.now())}',
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    color: sub,
                  ),
                ),
                if (reprintDate != null)
                  Text(
                    'Reprinted: ${_formatDate(reprintDate!)}',
                    style: TextStyle(
                      fontSize: context.getRFontSize(12),
                      color: Colors.red.shade700,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
          ),

          SizedBox(height: context.getRSize(12)),
          Container(height: 1, color: divCol),
          SizedBox(height: context.getRSize(12)),

          ...cart.map((item) {
            final rawQty = item['qty'];
            final double qty = rawQty is num
                ? rawQty.toDouble()
                : double.tryParse(rawQty.toString()) ?? 0.0;

            final rawPrice = item['price'];
            final double price = rawPrice is num
                ? rawPrice.toDouble()
                : double.tryParse(rawPrice.toString()) ?? 0.0;

            final lineTotal = stockValue(price, qty).round();
            return Padding(
              padding: EdgeInsets.symmetric(vertical: context.getRSize(4)),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${productDisplayName(item['name'] as String, item['size'] as String?, unit: item['unit'] as String?)}  ×${qty.toStringAsFixed(1)}',
                      style: TextStyle(
                        fontSize: context.getRFontSize(13),
                        color: textCol,
                      ),
                    ),
                  ),
                  Text(
                    formatCurrency(lineTotal),
                    style: TextStyle(
                      fontSize: context.getRFontSize(13),
                      fontWeight: FontWeight.w600,
                      color: textCol,
                    ),
                  ),
                ],
              ),
            );
          }),

          SizedBox(height: context.getRSize(12)),
          Container(height: 1, color: divCol),
          SizedBox(height: context.getRSize(12)),

          _infoRow(context, 'Subtotal', subtotal, sub),
          if (crateDeposit > 0) ...[
            SizedBox(height: context.getRSize(4)),
            // Build per-manufacturer crate breakdown when names are available.
            if (manufacturerNames != null && manufacturerNames!.isNotEmpty) ...[
              () {
                // Group crate cart items by manufacturerId
                final Map<String, double> mfrQty = {};
                for (final item in cart) {
                  final mid = item['manufacturerId'];
                  if (mid is String &&
                      (item['crateSizeGroupId'] != null ||
                          ((item['emptyCrateValueKobo'] ?? 0) as num) > 0)) {
                    mfrQty[mid] =
                        (mfrQty[mid] ?? 0) + (item['qty'] as num).toDouble();
                  }
                }
                if (mfrQty.isEmpty) {
                  return _infoRow(context, 'Crate Deposit', crateDeposit, sub);
                }
                final sortedEntries = mfrQty.entries.toList()
                  ..sort((a, b) {
                    final nameA = manufacturerNames![a.key] ?? '';
                    final nameB = manufacturerNames![b.key] ?? '';
                    return nameA.compareTo(nameB);
                  });
                return Column(
                  children:
                      sortedEntries.map((e) {
                        final mfrName = manufacturerNames![e.key] ?? 'Unknown';
                        return Padding(
                          padding: EdgeInsets.symmetric(
                            vertical: context.getRSize(2),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  '$mfrName (${e.value.toStringAsFixed(0)} crates)',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: context.getRFontSize(12),
                                    color: sub,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList()..add(
                        Padding(
                          padding: EdgeInsets.symmetric(
                            vertical: context.getRSize(2),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Crate Deposit',
                                style: TextStyle(
                                  fontSize: context.getRFontSize(13),
                                  color: sub,
                                ),
                              ),
                              Text(
                                formatCurrency(crateDeposit),
                                style: TextStyle(
                                  fontSize: context.getRFontSize(13),
                                  fontWeight: FontWeight.w600,
                                  color: sub,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                );
              }(),
            ] else
              _infoRow(context, 'Crate Deposit', crateDeposit, sub),
          ],

          SizedBox(height: context.getRSize(12)),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'TOTAL',
                style: TextStyle(
                  fontSize: context.getRFontSize(16),
                  fontWeight: FontWeight.bold,
                  color: textCol,
                ),
              ),
              Text(
                formatCurrency(total),
                style: TextStyle(
                  fontSize: context.getRFontSize(18),
                  fontWeight: FontWeight.w800,
                  color: primary,
                ),
              ),
            ],
          ),

          SizedBox(height: context.getRSize(16)),
          Container(height: 1, color: divCol),
          SizedBox(height: context.getRSize(16)),

          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Payment Method: $paymentMethod',
              style: TextStyle(
                fontSize: context.getRFontSize(13),
                fontWeight: FontWeight.w600,
                color: textCol,
              ),
            ),
          ),
          SizedBox(height: context.getRSize(4)),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Amount Paid: ${formatCurrency(cashReceived ?? total)}',
              style: TextStyle(fontSize: context.getRFontSize(13), color: sub),
            ),
          ),
          // §15.1 — wallet info, only when ticked at checkout.
          if (showWalletInfo && walletBalance != null) ...[
            SizedBox(height: context.getRSize(4)),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Wallet Balance: ${formatCurrency(walletBalance!)}'
                ' ${walletBalance! < 0 ? '(debt)' : '(credit)'}',
                style: TextStyle(
                  fontSize: context.getRFontSize(13),
                  fontWeight: FontWeight.w600,
                  color: textCol,
                ),
              ),
            ),
          ],

          SizedBox(height: context.getRSize(24)),
          Text(
            'Rider: ${riderName ?? 'Pick-up'}',
            style: TextStyle(
              fontSize: context.getRFontSize(13),
              fontWeight: FontWeight.bold,
              color: textCol,
            ),
          ),
          SizedBox(height: context.getRSize(24)),

          Text(
            'Thank you for your patronage!',
            style: TextStyle(
              fontSize: context.getRFontSize(13),
              fontWeight: FontWeight.w600,
              fontStyle: FontStyle.italic,
              color: sub,
            ),
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            'Powered by Reebaplus+',
            style: TextStyle(fontSize: context.getRFontSize(10), color: sub),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(BuildContext context, String label, double value, Color col) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(2)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: context.getRFontSize(13), color: col),
          ),
          Text(
            formatCurrency(value),
            style: TextStyle(
              fontSize: context.getRFontSize(13),
              fontWeight: FontWeight.w600,
              color: col,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}, '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
