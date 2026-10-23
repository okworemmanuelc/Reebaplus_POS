import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/widgets/sales_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/core/utils/product_unit.dart';

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
        title: Text(
          'Replace barcode?',
          style: ctx.screenTitleStyle.copyWith(
            color: Theme.of(ctx).colorScheme.onSurface,
          ),
        ),
        content: Text(
          'This replaces barcode $oldBarcode on $name. Continue?',
          style: ctx
              .regularStyle(14)
              .copyWith(color: Theme.of(ctx).colorScheme.onSurface),
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            isFullWidth: false,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            text: 'Continue',
            variant: AppButtonVariant.primary,
            isFullWidth: false,
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
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final results = _results;

    // A fixed share of the space the sheet is given, so the sheet doesn't jump
    // as the results change. The keyboard is handled by MainLayout's Scaffold
    // resize (which shrinks this space), so the bottom padding is nav-only
    // (deviceBottomPadding) and everything scrolls — header, field and rows —
    // so a short (landscape + keyboard) viewport never overflows.
    return LayoutBuilder(
      builder: (context, constraints) => Container(
        height: constraints.maxHeight * 0.85,
        decoration: salesSheetDecoration(context),
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                context.getRSize(20),
                context.getRSize(12),
                context.getRSize(20),
                0,
              ),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SalesSheetHeader(
                      title: 'Link to a product',
                      subtitle: 'Barcode ${widget.code}',
                      leading: const IconTile(icon: AppIcons.link, size: 44),
                      trailing: [
                        SalesBackButton(
                          icon: AppIcons.close,
                          tooltip: 'Close',
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    SizedBox(height: context.getRSize(16)),
                    AppInput(
                      controller: _searchCtrl,
                      hintText: 'Search products by name',
                      prefixIcon: Icon(
                        AppIcons.search,
                        size: context.getRSize(18),
                        color: muted,
                      ),
                      textInputAction: TextInputAction.search,
                      onChanged: _search,
                    ),
                    SizedBox(height: context.getRSize(16)),
                    if (results != null && results.isEmpty)
                      Text(
                        'No products match',
                        textAlign: TextAlign.center,
                        style: context.semiBoldStyle(14).copyWith(color: muted),
                      ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                context.getRSize(20),
                0,
                context.getRSize(20),
                context.deviceBottomPadding + context.getRSize(20),
              ),
              sliver: SliverList.separated(
                itemCount: results?.length ?? 0,
                separatorBuilder: (_, _) =>
                    SizedBox(height: context.getRSize(8)),
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
class _ScanLinkRow extends ConsumerWidget {
  const _ScanLinkRow({required this.product, required this.onTap});

  final ProductData product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final text = t.colorScheme.onSurface;
    final muted = t.textTheme.bodySmall?.color ?? text;
    // Same size + unit descriptor the POS grid tile shows under the name.
    final crates = businessTracksCrates(ref.watch(currentBusinessProvider));
    final size =
        '${product.size ?? ''} ${unitLabel(product.unit, crates: crates) ?? ''}'
            .trim();
    final barcode = product.barcode?.trim() ?? '';
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);

    return DecoratedBox(
      decoration: AppDecorations.card(
        context,
        radius: AppSpacing.borderRadiusL,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: ValueKey<String>('$kScanLinkRowKeyPrefix${product.id}'),
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(12)),
              child: Row(
                children: [
                  const IconTile(icon: AppIcons.box, size: 40),
                  SizedBox(width: context.getRSize(10)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          size.isEmpty
                              ? product.name
                              : '${product.name} · $size',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context.boldStyle(15).copyWith(color: text),
                        ),
                        SizedBox(height: context.getRSize(2)),
                        Text(
                          barcode.isEmpty
                              ? 'No barcode yet'
                              : 'Barcode $barcode',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context
                              .regularStyle(12)
                              .copyWith(color: muted),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  AppIcon(
                    AppIcons.chevronRight,
                    size: context.getRSize(20),
                    color: muted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
