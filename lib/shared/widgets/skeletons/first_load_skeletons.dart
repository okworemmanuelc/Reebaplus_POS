import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/skeletons/skeleton.dart';

/// Lightweight, non-blocking skeletons for the four first-load landing
/// destinations (brief §4.4). Each composes the shared [SkeletonBox] /
/// [SkeletonLine] primitives under a single [Shimmer] and mirrors the rough
/// shape of its real screen, so a fresh-device user understands data is on the
/// way rather than seeing a blank screen. None of them scroll or capture input —
/// they sit in place until the tab's real content streams in.

/// POS — a placeholder product grid.
class PosSkeleton extends StatelessWidget {
  const PosSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final gap = context.getRSize(12);
    return Shimmer(
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Search bar placeholder.
            SkeletonBox(height: context.getRSize(44), radius: 14),
            SizedBox(height: gap),
            // Category chips row.
            Row(
              children: List.generate(
                4,
                (i) => Padding(
                  padding: EdgeInsets.only(right: context.getRSize(8)),
                  child: SkeletonBox(
                    width: context.getRSize(64),
                    height: context.getRSize(30),
                    radius: 16,
                  ),
                ),
              ),
            ),
            SizedBox(height: gap),
            // Product grid.
            Expanded(
              child: GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 8,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: gap,
                  crossAxisSpacing: gap,
                  childAspectRatio: 0.85,
                ),
                itemBuilder: (_, __) => const _CardSkeleton(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Home / dashboard — placeholder summary cards over a short list.
class HomeSkeleton extends StatelessWidget {
  const HomeSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final gap = context.getRSize(16);
    return Shimmer(
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.all(context.getRSize(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Two big stat cards side by side.
            Row(
              children: [
                Expanded(
                  child: SkeletonBox(height: context.getRSize(96), radius: 18),
                ),
                SizedBox(width: gap),
                Expanded(
                  child: SkeletonBox(height: context.getRSize(96), radius: 18),
                ),
              ],
            ),
            SizedBox(height: gap),
            SkeletonBox(height: context.getRSize(120), radius: 18),
            SizedBox(height: gap),
            // A short activity list.
            for (var i = 0; i < 4; i++)
              Padding(
                padding: EdgeInsets.only(bottom: context.getRSize(12)),
                child: const _RowSkeleton(),
              ),
          ],
        ),
      ),
    );
  }
}

/// Inventory — a placeholder list of product rows.
class InventorySkeleton extends StatelessWidget {
  const InventorySkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.all(context.getRSize(16)),
        itemCount: 8,
        itemBuilder: (_, __) => Padding(
          padding: EdgeInsets.only(bottom: context.getRSize(12)),
          child: const _RowSkeleton(),
        ),
      ),
    );
  }
}

/// Reports — a placeholder grid of report cards.
class ReportsSkeleton extends StatelessWidget {
  const ReportsSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final gap = context.getRSize(16);
    return Shimmer(
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.all(context.getRSize(16)),
        itemCount: 6,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: gap,
          crossAxisSpacing: gap,
          childAspectRatio: 1.3,
        ),
        itemBuilder: (_, __) => SkeletonBox(radius: context.getRSize(18)),
      ),
    );
  }
}

/// A product-card-shaped skeleton: image area on top, two text lines below.
class _CardSkeleton extends StatelessWidget {
  const _CardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: SkeletonBox(radius: context.getRSize(16))),
        SizedBox(height: context.getRSize(8)),
        const SkeletonLine(widthFactor: 0.8),
        SizedBox(height: context.getRSize(6)),
        const SkeletonLine(widthFactor: 0.5),
      ],
    );
  }
}

/// A list-row-shaped skeleton: leading square + two stacked text lines.
class _RowSkeleton extends StatelessWidget {
  const _RowSkeleton();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SkeletonBox(
          width: context.getRSize(48),
          height: context.getRSize(48),
          radius: 12,
        ),
        SizedBox(width: context.getRSize(12)),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonLine(widthFactor: 0.6),
              SizedBox(height: 8),
              SkeletonLine(widthFactor: 0.35),
            ],
          ),
        ),
      ],
    );
  }
}
