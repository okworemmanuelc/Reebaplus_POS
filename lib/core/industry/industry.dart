import 'package:flutter/material.dart';

/// A trade the app can be set up for — the single input that morphs the app's
/// words, presets, and optional feature surfaces (CONTEXT.md → *Industry*).
///
/// This enum **is** the one Industry registry (ADR 0015): the single source of
/// truth for each industry's display label, icon, coming-soon flag, and
/// crate-eligibility. It supersedes the two lists these facts used to be split
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

  /// The one industry live today. The DB stores the legacy canonical string
  /// `'Beer distributor'` for these tenants (mapped to this display label at
  /// load/save), so [aliases] carries it for resolution.
  beverage(
    label: 'Beverage distributor',
    icon: Icons.sports_bar_rounded,
    comingSoon: false,
    crateEligible: true,
    aliases: {'beer distributor'},
  ),
  pharmacy(label: 'Pharmacy', icon: Icons.local_pharmacy_rounded),
  buildingMaterials(label: 'Building Materials', icon: Icons.foundation_rounded),
  boutique(label: 'Boutique', icon: Icons.checkroom_rounded),

  /// Safe fallback for an unknown, legacy, or null `businesses.type`. Never
  /// offered in a picker (excluded from [catalogue]); it exists so [industryOf]
  /// is total and the interior falls back to neutral words and no
  /// industry-only features.
  generic(
    label: 'Business',
    icon: Icons.storefront_rounded,
    comingSoon: false,
  );

  const Industry({
    required this.label,
    required this.icon,
    this.comingSoon = true,
    this.crateEligible = false,
    this.aliases = const <String>{},
  });

  /// Canonical display label (what onboarding writes to `businesses.type` and
  /// what the type pickers show).
  final String label;

  /// Icon shown beside the label in the onboarding picker.
  final IconData icon;

  /// Whether this industry is greyed-out as "coming soon" at onboarding. #77
  /// preserves today's set (only [beverage] selectable); #79 flips all off.
  final bool comingSoon;

  /// Whether this industry uses the empty-crate features (Bar / Beverage only).
  /// The crate-visibility gate reads this via [isCrateBusiness]; combine it with
  /// the `tracks_empty_crates` opt-in for the full surface gate.
  final bool crateEligible;

  /// Extra lowercase strings (besides the lowercased [label]) that resolve to
  /// this industry — legacy DB canonicals and casings. See [industryOf].
  final Set<String> aliases;

  /// The industries offered in pickers, in plan order — every entry except
  /// [generic]. Onboarding and Settings render from this so the two lists can
  /// never diverge from the registry.
  static List<Industry> get catalogue =>
      values.where((i) => i != generic).toList(growable: false);
}

/// Resolves a stored `businesses.type` string to its [Industry]. Total: known
/// display labels and legacy aliases map to their industry (case-insensitive,
/// trimmed); anything unknown, empty, or null maps to [Industry.generic]. Never
/// throws.
Industry industryOf(String? type) {
  final t = type?.trim().toLowerCase();
  if (t == null || t.isEmpty) return Industry.generic;
  for (final ind in Industry.values) {
    if (ind == Industry.generic) continue;
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
