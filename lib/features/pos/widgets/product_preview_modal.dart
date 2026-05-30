import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

class ProductPreviewModal extends ConsumerStatefulWidget {
  final ProductData product;
  final int totalStock;
  final Color cardCol;
  final Color textCol;
  final Color subtextCol;

  const ProductPreviewModal({
    super.key,
    required this.product,
    required this.totalStock,
    required this.cardCol,
    required this.textCol,
    required this.subtextCol,
  });

  @override
  ConsumerState<ProductPreviewModal> createState() =>
      _ProductPreviewModalState();
}

class _ProductPreviewModalState extends ConsumerState<ProductPreviewModal>
    with SingleTickerProviderStateMixin {
  String? _manufacturerName;
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _scaleAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutBack,
    );

    _opacityAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeIn,
    );

    _animationController.forward();
    _resolveManufacturerName();
  }

  Future<void> _resolveManufacturerName() async {
    final id = widget.product.manufacturerId;
    if (id == null) return;
    final mfrs =
        await ref.read(databaseProvider).inventoryDao.getAllManufacturers();
    if (!mounted) return;
    setState(() {
      _manufacturerName =
          mfrs.where((m) => m.id == id).map((m) => m.name).firstOrNull;
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.product;
    final theme = Theme.of(context);
    final primaryColor = product.colorHex != null
        ? Color(int.parse(product.colorHex!.replaceAll('#', '0xFF')))
        : theme.colorScheme.primary;

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      child: Center(
        child: AnimatedBuilder(
          animation: _animationController,
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAnimation.value,
              child: Opacity(opacity: _opacityAnimation.value, child: child),
            );
          },
          child: Container(
            width: context.screenWidth * 0.85,
            padding: EdgeInsets.all(context.getRSize(24)),
            decoration: BoxDecoration(
              color: widget.cardCol.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(32),
              border: Border.all(
                color: widget.textCol.withValues(alpha: 0.1),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 30,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header with Icon
                  Row(
                    children: [
                      Container(
                        padding: EdgeInsets.all(context.getRSize(12)),
                        decoration: BoxDecoration(
                          color: primaryColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: product.imagePath != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: Image.file(
                                  File(product.imagePath!),
                                  width: context.getRSize(48),
                                  height: context.getRSize(48),
                                  fit: BoxFit.cover,
                                  errorBuilder: (ctx, _, __) => Icon(
                                    FontAwesomeIcons.beerMugEmpty,
                                    color: primaryColor,
                                    size: context.getRSize(24),
                                  ),
                                ),
                              )
                            : Icon(
                                FontAwesomeIcons.beerMugEmpty,
                                color: primaryColor,
                                size: context.getRSize(24),
                              ),
                      ),
                      SizedBox(width: context.getRSize(16)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              product.name,
                              style: TextStyle(
                                fontSize: context.getRFontSize(20),
                                fontWeight: FontWeight.bold,
                                color: widget.textCol,
                              ),
                            ),
                            if (product.subtitle != null &&
                                product.subtitle!.isNotEmpty)
                              Text(
                                product.subtitle!,
                                style: TextStyle(
                                  fontSize: context.getRFontSize(14),
                                  color: widget.subtextCol,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: context.getRSize(24)),

                  // Details Grid
                  _buildDetailRow(
                    context,
                    FontAwesomeIcons.store,
                    'Current Stock',
                    '${widget.totalStock} ${product.unit}',
                    primaryColor,
                  ),
                  const Divider(height: 24, thickness: 0.5),
                  _buildDetailRow(
                    context,
                    FontAwesomeIcons.tag,
                    'Retailer Price',
                    formatCurrency(product.retailerPriceKobo / 100),
                    theme.colorScheme.primary,
                  ),
                  _buildDetailRow(
                    context,
                    FontAwesomeIcons.users,
                    'Wholesaler Price',
                    formatCurrency(product.wholesalerPriceKobo / 100),
                    theme.colorScheme.secondary,
                  ),
                  const Divider(height: 24, thickness: 0.5),
                  _buildDetailRow(
                    context,
                    FontAwesomeIcons.industry,
                    'Manufacturer',
                    _manufacturerName ?? 'N/A',
                    const Color(0xFF8B5CF6),
                  ),
                  _buildDetailRow(
                    context,
                    FontAwesomeIcons.boxOpen,
                    'Size',
                    product.size ?? 'N/A',
                    const Color(0xFFEC4899),
                  ),

                  SizedBox(height: context.getRSize(16)),
                  Center(
                    child: Text(
                      'Release to close',
                      style: TextStyle(
                        fontSize: context.getRFontSize(12),
                        fontStyle: FontStyle.italic,
                        color: widget.subtextCol.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(
    BuildContext context,
    IconData icon,
    String label,
    String value,
    Color iconColor,
  ) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(6)),
      child: Row(
        children: [
          Icon(icon, size: context.getRSize(14), color: iconColor),
          SizedBox(width: context.getRSize(12)),
          Text(
            label,
            style: TextStyle(
              fontSize: context.getRFontSize(14),
              color: widget.subtextCol,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: context.getRFontSize(14),
              fontWeight: FontWeight.bold,
              color: widget.textCol,
            ),
          ),
        ],
      ),
    );
  }
}
