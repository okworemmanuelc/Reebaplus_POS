import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/features/receiving/widgets/new_product_card.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/update_product_sheet.dart';

class ReceiveProductGrid extends ConsumerWidget {
  final List<ProductDataWithStock> products;
  final Color cardCol;
  final Color textCol;
  final Color subtextCol;
  final Color borderCol;
  final int gridColumns;

  const ReceiveProductGrid({
    super.key,
    required this.products,
    required this.cardCol,
    required this.textCol,
    required this.subtextCol,
    required this.borderCol,
    this.gridColumns = 3,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screenWidth = MediaQuery.of(context).size.width;
    int effectiveColumns = gridColumns;

    if (screenWidth < 380) {
      if (effectiveColumns > 2) effectiveColumns = 2;
    } else if (screenWidth > 600) {
      final dynamicColumns = (screenWidth / 180).floor();
      effectiveColumns = max(effectiveColumns, dynamicColumns);
    }

    final totalPadding = context.getRSize(16);
    final totalSpacing = context.getRSize(8) * (effectiveColumns - 1);
    final cellWidth = (screenWidth - totalPadding - totalSpacing) / effectiveColumns;
    final aspect = cellWidth / context.getRSize(210);

    // Add 1 for the NewProductCard
    return GridView.builder(
      padding: EdgeInsets.all(context.getRSize(8)),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: effectiveColumns,
        childAspectRatio: aspect,
        crossAxisSpacing: context.getRSize(8),
        mainAxisSpacing: context.getRSize(8),
      ),
      itemCount: products.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return NewProductCard(
            cardCol: cardCol,
            textCol: textCol,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (ctx) => AddProductScreen(
                    onProductAdded: (product) {
                      ref.read(receiveCartProvider.notifier).addOrIncrement(product);
                    },
                  ),
                ),
              );
            },
          );
        }
        final item = products[index - 1];
        return _ReceiveProductCard(
          item: item,
          cardCol: cardCol,
          textCol: textCol,
          subtextCol: subtextCol,
          borderCol: borderCol,
        );
      },
    );
  }
}

class _ReceiveProductCard extends ConsumerWidget {
  final ProductDataWithStock item;
  final Color cardCol;
  final Color textCol;
  final Color subtextCol;
  final Color borderCol;

  const _ReceiveProductCard({
    required this.item,
    required this.cardCol,
    required this.textCol,
    required this.subtextCol,
    required this.borderCol,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final product = item.product;
    final cartLines = ref.watch(receiveCartProvider);
    final cartLine = cartLines.where((l) => l.productId == product.id).firstOrNull;
    final inCart = cartLine != null;
    final cartQty = cartLine?.qty ?? 0;
    
    // Out of stock is fully tappable here.
    final bool isOutOfStock = item.totalStock <= 0;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        GestureDetector(
          onLongPress: () {
            if (!hasPermission(ref, 'products.edit_price')) {
              AppNotification.showError(context, 'You lack permission to edit products.');
              return;
            }
            showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (ctx) => UpdateProductSheet(
                product: product,
                totalStock: item.totalStock,
                onProductUpdated: (updatedProduct) {
                  ref.read(receiveCartProvider.notifier).addOrIncrement(updatedProduct);
                },
              ),
            );
          },
          child: InkWell(
            onTap: () {
              ref.read(receiveCartProvider.notifier).addOrIncrement(product);
            },
            borderRadius: BorderRadius.circular(16),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: cardCol,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: inCart ? Theme.of(context).colorScheme.primary : Colors.transparent,
                  width: inCart ? 2.0 : 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: inCart
                        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
                        : Colors.black.withValues(alpha: 0.02),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: _buildGridLayout(context, product, item.totalStock, isOutOfStock),
            ),
          ),
        ),
        if (inCart)
          Positioned(
            top: -8,
            right: -8,
            child: Container(
              width: context.getRSize(30),
              height: context.getRSize(30),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.45),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  cartQty.toString(),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimary,
                    fontSize: context.getRFontSize(11),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildGridLayout(BuildContext context, ProductData product, int totalStock, bool isOutOfStock) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Center(
              child: product.imagePath != null
                  ? Image.file(
                      File(product.imagePath!),
                      width: double.infinity,
                      height: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (ctx, _, __) => _buildPlaceholderText(context, product.name),
                    )
                  : _buildPlaceholderText(context, product.name),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.all(context.getRSize(12)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                product.name,
                style: TextStyle(
                  fontSize: context.getRFontSize(14),
                  fontWeight: FontWeight.w800,
                  color: textCol,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: context.getRSize(2)),
              Text(
                '${product.size != null && product.size!.isNotEmpty ? '${product.size} ' : ''}${product.unit}'.trim(),
                style: TextStyle(
                  fontSize: context.getRFontSize(11),
                  color: subtextCol,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: context.getRSize(8)),
              Text(
                isOutOfStock ? 'No stock' : 'Current: $totalStock',
                style: TextStyle(
                  fontSize: context.getRFontSize(11),
                  color: isOutOfStock ? Theme.of(context).colorScheme.error : subtextCol,
                  fontWeight: isOutOfStock ? FontWeight.bold : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlaceholderText(BuildContext context, String name) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.getRSize(8)),
      child: Text(
        name,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: context.getRFontSize(16),
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}
