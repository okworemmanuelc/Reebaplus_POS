import 'package:flutter/material.dart';

/// A trade the app can be set up for — the single input that morphs the app's
/// words, presets, and optional feature surfaces (CONTEXT.md → *Industry*).
///
/// This enum **is** the one Industry registry (ADR 0015): the single source of
/// truth for each industry's display label, icon, coming-soon flag,
/// crate-eligibility, and picker selectability. It supersedes the two lists
/// these facts used to be split
/// across — the `kBusinessTypes` display list and the private `_businessTypes`
/// record list in CEO Sign Up — so the two can no longer drift.
///
/// An industry is a *configuration profile* over the one shared
/// products/POS/inventory model, never a separate data model or app. Identity
/// is resolved from the stored `businesses.type` string by [industryOf]; there
/// is no `industry_id` column and no migration. Anything unknown or null
/// resolves to [generic] — a safe fallback so a legacy or malformed type never
/// crashes or blanks the app.
///
/// Later slices of PRD #76 hang more configuration off each entry (the Lexicon
/// of domain nouns, starter categories/units, further feature flags); #77
/// introduces only the facts that were already duplicated.
enum Industry {
  restaurant(label: 'Restaurant', icon: Icons.restaurant_rounded),
  supermarket(label: 'Supermarket', icon: Icons.local_grocery_store_rounded),
  bar(label: 'Bar', icon: Icons.local_bar_rounded, crateEligible: true),

  /// The one industry that was live before the multi-industry unlock (#79). The
  /// DB stores the legacy canonical `'Beer distributor'` for these tenants
  /// (mapped to this display label at load/save), so [aliases] carries it.
  beverage(
    label: 'Beverage distributor',
    icon: Icons.sports_bar_rounded,
    crateEligible: true,
    selectable: true,
    aliases: {'beer distributor'},
  ),
  pharmacy(
    label: 'Pharmacy',
    icon: Icons.local_pharmacy_rounded,
    selectable: true,
  ),
  buildingMaterials(label: 'Building Materials', icon: Icons.foundation_rounded),
  boutique(label: 'Boutique', icon: Icons.checkroom_rounded),

  /// New in the multi-industry unlock (#79). No crate features (bottle/crate
  /// tracking stays Bar/Beverage-only); deeper serial/IMEI capture is a later,
  /// separately-flagged slice (ADR 0015).
  phoneAndGadgets(label: 'Phone & Gadgets', icon: Icons.smartphone_rounded),

  /// New in the multi-industry unlock (#79). No crate features; cold-chain /
  /// expiry emphasis is a later per-industry slice (ADR 0015).
  frozenFoodsAndGrocery(
    label: 'Frozen Foods & Grocery',
    icon: Icons.ac_unit_rounded,
    selectable: true,
  ),

  /// Safe fallback for an unknown, legacy, or null `businesses.type`. Never
  /// offered in a picker (excluded from [catalogue]); it exists so [industryOf]
  /// is total and the interior falls back to neutral words and no
  /// industry-only features.
  generic(label: 'Business', icon: Icons.storefront_rounded);

  const Industry({
    required this.label,
    required this.icon,
    // No entry sets this after the #79 unlock (see the [comingSoon] field doc),
    // hence the suppression.
    // ignore: unused_element_parameter
    this.comingSoon = false,
    this.crateEligible = false,
    this.selectable = false,
    this.aliases = const <String>{},
  });

  /// Canonical display label (what onboarding writes to `businesses.type` and
  /// what the type pickers show).
  final String label;

  /// Icon shown beside the label in the onboarding picker.
  final IconData icon;

  /// Whether this industry is greyed-out as "coming soon" at onboarding. All
  /// nine are unlocked (#79), so this is uniformly false today; the flag stays
  /// in the registry (PRD #76) so a future industry can ship gated.
  final bool comingSoon;

  /// Whether this industry uses the empty-crate features (Bar / Beverage only).
  /// The crate-visibility gate reads this via [isCrateBusiness]; combine it with
  /// the `tracks_empty_crates` opt-in for the full surface gate.
  final bool crateEligible;

  /// Whether this industry is offered in the onboarding + Settings pickers.
  /// Only Beverage distributor, Pharmacy, and Frozen Foods & Grocery ship
  /// selectable today (issue #112); the other trades stay in the registry so
  /// existing tenants keep normalizing + their features, but appear in no
  /// picker. New industries default to hidden — flip this deliberately once
  /// their flow is ready. [generic] is never selectable.
  final bool selectable;

  /// Extra lowercase strings (besides the lowercased [label]) that resolve to
  /// this industry — legacy DB canonicals and casings. See [industryOf].
  final Set<String> aliases;

  /// The full registry of real industries, in plan order — every entry except
  /// [generic]. This is what [industryOf] normalizes against and what the
  /// business-type round-trip validates against, so it keeps ALL nine even
  /// though the pickers now offer only [selectableCatalogue]: a tenant on a
  /// now-hidden trade must still resolve to its own profile and keep its
  /// features (no data migration, issue #112). Computed once.
  static final List<Industry> catalogue =
      values.where((i) => i != generic).toList(growable: false);

  /// The industries actually offered in the onboarding + Settings pickers — the
  /// [selectable] subset of [catalogue], in plan order (issue #112). Onboarding
  /// and Settings render from this so the two pickers can never diverge from the
  /// registry or offer a hidden trade. Computed once (used inside `build`).
  static final List<Industry> selectableCatalogue =
      values.where((i) => i.selectable).toList(growable: false);
}

/// Resolves a stored `businesses.type` string to its [Industry]. Total: known
/// display labels and legacy aliases map to their industry (case-insensitive,
/// trimmed); anything unknown, empty, or null maps to [Industry.generic]. Never
/// throws.
Industry industryOf(String? type) {
  final t = type?.trim().toLowerCase();
  if (t == null || t.isEmpty) return Industry.generic;
  for (final ind in Industry.catalogue) {
    if (ind.label.toLowerCase() == t || ind.aliases.contains(t)) return ind;
  }
  return Industry.generic;
}

/// Whether [type] is a business that uses empty-crate features — Bar or
/// Beverage distributor only (master plan §16.10). Derived from the registry's
/// [Industry.crateEligible] flag so "bar/beverage only" stays consistent
/// everywhere, including the server gate. The single gate for crate-feature
/// visibility; reuse it instead of re-comparing raw strings.
///
/// Case-insensitive and trimmed on purpose: businesses onboarded by older
/// builds stored non-canonical casings (e.g. 'Beer Distributor'), which
/// [industryOf] normalizes — keeping the gate correct for that legacy data
/// without a risky migration of synced rows.
bool isCrateBusiness(String? type) => industryOf(type).crateEligible;
