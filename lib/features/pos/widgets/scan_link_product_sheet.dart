import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Key prefix for a link-search result row; the product id follows (tests find
/// a row by it).
const String kScanLinkRowKeyPrefix = 'scan-link-';

/// The "Link to an existing product" search (#321, PRD #316), shown over the
/// scanner after an unknown code. Lists this business's non-deleted products
/// by name ([CatalogDao.searchProductsByName]); a blank search lists the first
/// ones. Tapping a product with no barcode (or already this [code]) pops the
/// sheet with it. Tapping one that carries a DIFFERENT barcode first asks
/// "This replaces barcode ‹old› on ‹name›. Continue?" — Cancel keeps the
/// search open. The sheet saves nothing itself: the caller writes the barcode
/// and dismissing returns null.
class ScanLinkProductSheet extends ConsumerStatefulWidget {
  const ScanLinkProductSheet({super.key, required this.code});

  /// The scanned barcode being linked.
  final String code;

  /// Opens the search over [context]; returns the confirmed product, or null
  /// when dismissed.
  static Future<ProductData?> show(
    BuildContext context, {
    required String code,
  }) {
    return showModalBottomSheet<ProductData>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ScanLinkProductSheet(code: code),
    );
  }

  @override
  ConsumerState<ScanLinkProductSheet> createState() =>
      _ScanLinkProductSheetState();
}

class _ScanLinkProductSheetState extends ConsumerState<ScanLinkProductSheet> {
  final _searchCtrl = TextEditingController();
  List<ProductData>? _results;
  // Bumped per search so a slow, older query can't overwrite a newer one.
  int _searchSeq = 0;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    final seq = ++_searchSeq;
    final hits = await ref
        .read(databaseProvider)
        .catalogDao
        .searchProductsByName(query);
    if (!mounted || seq != _searchSeq) return;
    setState(() => _results = hits);
  }

  Future<void> _pick(ProductData product) async {
    final old = product.barcode?.trim() ?? '';
    if (old.isNotEmpty && old != widget.code) {
      final ok = await _confirmReplace(product.name, old);
      if (!ok || !mounted) return;
    }
    if (!mounted) return;
    Navigator.pop(context, product);
  }

  Future<bool> _confirmReplace(String name, String oldBarcode) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Text(
          'Replace barcode?',
          style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'This replaces barcode $oldBarcode on $name. Continue?',
          style: Theme.of(ctx).textTheme.bodyMedium,
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            text: 'Continue',
            variant: AppButtonVariant.primary,
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final border = t.dividerColor;
    final text = t.colorScheme.onSurface;
    final primary = t.colorScheme.primary;
    final results = _results;

    // A fixed share of the space the sheet is given, so the sheet doesn't jump
    // as the results change. The keyboard is handled by MainLayout's Scaffold
    // resize (which shrinks this space), so the bottom padding is nav-only
    // (deviceBottomPadding) and everything scrolls — header, field and rows —
    // so a short (landscape + keyboard) viewport never overflows.
    return LayoutBuilder(
      builder: (context, constraints) => Container(
        height: constraints.maxHeight * 0.85,
        decoration: BoxDecoration(
          color: t.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 30,
              offset: const Offset(0, -10),
            ),
          ],
        ),
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                context.getRSize(24),
                context.getRSize(16),
                context.getRSize(24),
                0,
              ),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Drag Handle
                    Center(
                      child: Container(
                        width: context.getRSize(40),
                        height: context.getRSize(4),
                        decoration: BoxDecoration(
                          color: border.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    SizedBox(height: context.getRSize(24)),

                    // Header with Icon
                    Row(
                      children: [
                        Container(
                          padding: EdgeInsets.all(context.getRSize(14)),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                primary.withValues(alpha: 0.2),
                                primary.withValues(alpha: 0.1),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Icon(
                            Icons.link,
                            size: context.getRSize(20),
                            color: primary,
                          ),
                        ),
                        SizedBox(width: context.getRSize(16)),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Link to a product',
                                style: TextStyle(
                                  fontSize: context.getRFontSize(20),
                                  fontWeight: FontWeight.w900,
                                  color: text,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              Text(
                                'Barcode ${widget.code}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: context.getRFontSize(14),
                                  color: text.withValues(alpha: 0.5),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Material(
                          color: border.withValues(alpha: 0.1),
                          shape: const CircleBorder(),
                          child: IconButton(
                            onPressed: () => Navigator.pop(context),
                            icon: Icon(
                              Icons.close,
                              size: context.getRSize(20),
                              color: text.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: context.getRSize(16)),
                    AppInput(
                      controller: _searchCtrl,
                      hintText: 'Search products by name',
                      prefixIcon: const Icon(Icons.search),
                      textInputAction: TextInputAction.search,
                      onChanged: _search,
                    ),
                    SizedBox(height: context.getRSize(16)),
                    if (results != null && results.isEmpty)
                      Text(
                        'No products match',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: context.getRFontSize(14),
                          color: text.withValues(alpha: 0.6),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                context.getRSize(24),
                0,
                context.getRSize(24),
                context.deviceBottomPadding + context.getRSize(24),
              ),
              sliver: SliverList.separated(
                itemCount: results?.length ?? 0,
                separatorBuilder: (_, _) =>
                    SizedBox(height: context.getRSize(10)),
                itemBuilder: (context, i) => _ScanLinkRow(
                  product: results![i],
                  onTap: () => _pick(results[i]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One tappable search result: the name (+ size) and its current barcode.
class _ScanLinkRow extends StatelessWidget {
  const _ScanLinkRow({required this.product, required this.onTap});

  final ProductData product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final border = t.dividerColor;
    final text = t.colorScheme.onSurface;
    // Same size + unit descriptor the POS grid tile shows under the name.
    final size = '${product.size ?? ''} ${product.unit ?? ''}'.trim();
    final barcode = product.barcode?.trim() ?? '';

    return Material(
      color: border.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: ValueKey<String>('$kScanLinkRowKeyPrefix${product.id}'),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(context.getRSize(14)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                size.isEmpty ? product.name : '${product.name} · $size',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.getRFontSize(15),
                  fontWeight: FontWeight.w800,
                  color: text,
                ),
              ),
              SizedBox(height: context.getRSize(4)),
              Text(
                barcode.isEmpty ? 'No barcode yet' : 'Barcode $barcode',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.getRFontSize(12),
                  fontWeight: FontWeight.w600,
                  color: text.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
