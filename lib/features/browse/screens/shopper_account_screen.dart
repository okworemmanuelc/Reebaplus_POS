import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/storefront/shopper_age_confirmation.dart';
import 'package:reebaplus_pos/core/storefront/shopper_cart.dart';
import 'package:reebaplus_pos/core/storefront/shopper_providers.dart';
import 'package:reebaplus_pos/core/storefront/shopper_session.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/browse/screens/my_orders_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/shopper_details_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/shopper_sign_in_screen.dart';
import 'package:reebaplus_pos/features/browse/widgets/browse_parts.dart';
import 'package:reebaplus_pos/features/browse/widgets/shopper_parts.dart';
import 'package:reebaplus_pos/features/browse/widgets/shopper_texts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// The Shopper's account (#426, stories 40–41): who is signed in, their
/// details (edit), My orders, and a plain sign-out — no device wipe, the cart
/// stays. A business phone shops with its business sign-in and has no
/// Shopper sign-out here (ADR 0030). Delete account (#438) erases the
/// Shopper's data, clears the cart and signs a Shopper-only phone out; a
/// business phone keeps its sign-in.
class ShopperAccountScreen extends ConsumerWidget {
  const ShopperAccountScreen({super.key});

  void _toast(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _download(BuildContext context, WidgetRef ref) async {
    try {
      final data = await ref.read(shopperServiceProvider).exportData();
      await ref.read(shopperExportSharerProvider)(data);
    } catch (_) {
      if (context.mounted) {
        _toast(context, "Couldn't get your data. Check your connection.");
      }
    }
  }

  Future<void> _setMarketing(
    BuildContext context,
    WidgetRef ref,
    bool value,
  ) async {
    try {
      await ref.read(shopperServiceProvider).setMarketingOptIn(value);
      ref.invalidate(shopperProfileProvider);
    } catch (_) {
      if (context.mounted) {
        _toast(context, "Couldn't save that. Check your connection.");
      }
    }
  }

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('Your cart stays on this phone.'),
        actions: [
          AppButton(
            text: 'Stay signed in',
            variant: AppButtonVariant.ghost,
            isFullWidth: false,
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          AppButton(
            key: const Key('shopper-sign-out-confirm'),
            text: 'Sign out',
            isFullWidth: false,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(shopperSessionProvider.notifier).signOut();
  }

  Future<void> _deleteAccount(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('Delete your account?'),
        content: const Text(
          'Your details, saved phones and addresses are erased and orders '
          'the shops have not answered yet are cancelled. Shops keep the '
          'records of orders they already answered. This cannot be undone.',
        ),
        actions: [
          AppButton(
            text: 'Keep account',
            variant: AppButtonVariant.ghost,
            isFullWidth: false,
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          AppButton(
            key: const Key('shopper-delete-account-confirm'),
            text: 'Delete account',
            variant: AppButtonVariant.danger,
            isFullWidth: false,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(shopperServiceProvider).deleteAccount();
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text("Couldn't delete your account. Check your connection."),
        ),
      );
      return;
    }
    // The account_deleted email is sent server-side by the RPC (0229).
    await ref.read(shopperCartProvider.notifier).clear();
    await ref.read(shopperAgeConfirmationProvider.notifier).forget();
    final session = ref.read(shopperSessionProvider.notifier);
    if (ref.read(shopperSessionProvider).canSignOut) {
      await session.signOut();
    } else {
      ref.invalidate(shopperProfileProvider);
      ref.invalidate(shopperOrdersProvider);
    }
    messenger.showSnackBar(
      const SnackBar(content: Text('Your account has been deleted.')),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final session = ref.watch(shopperSessionProvider);
    if (!session.isSignedIn) {
      return ShopperPage(
        icon: AppIcons.user,
        title: 'Your account',
        body: BrowseMessage(
          key: const Key('shopper-account-signed-out'),
          icon: AppIcons.user,
          title: 'Sign in to see your orders',
          text: 'You only need an account to place an order.',
          actionLabel: 'Sign in',
          onAction: () => Navigator.of(context).push(
            MaterialPageRoute<bool>(
              builder: (_) => const ShopperSignInScreen(),
            ),
          ),
        ),
      );
    }
    final profile = ref.watch(shopperProfileProvider);
    final details = profile.valueOrNull;
    return ShopperPage(
      icon: AppIcons.user,
      title: 'Your account',
      subtitle: session.email,
      body: ListView(
        key: const Key('shopper-account-list'),
        padding: EdgeInsets.all(context.getRSize(16)),
        children: [
          ShopperSection(
            title: 'Your details',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (profile.isLoading)
                  const Center(child: CircularProgressIndicator())
                else if (details == null)
                  Text(
                    "You haven't added your details yet.",
                    style: context.regularStyle(14).copyWith(color: muted),
                  )
                else ...[
                  Text(details.name, style: context.boldStyle(15)),
                  if (details.defaultPhone != null)
                    Text(
                      details.defaultPhone!.phone,
                      style: context.regularStyle(14),
                    ),
                  if (details.defaultAddress != null)
                    Text(
                      details.defaultAddress!.label,
                      style: context.regularStyle(14),
                    ),
                ],
                SizedBox(height: context.getRSize(8)),
                Text(
                  kShopperSharingNotice,
                  style: context.regularStyle(12).copyWith(color: muted),
                ),
                SizedBox(height: context.getRSize(8)),
                AppButton(
                  key: const Key('shopper-edit-details'),
                  text: details == null ? 'Add details' : 'Edit details',
                  icon: AppIcons.userEdit,
                  variant: AppButtonVariant.outline,
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ShopperDetailsScreen(initial: details),
                    ),
                  ),
                ),
              ],
            ),
          ),
          ShopperSection(
            title: 'Privacy',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  kShopperPrivacyNotice,
                  key: const Key('shopper-privacy-notice'),
                  style: context.regularStyle(12).copyWith(color: muted),
                ),
                if (details != null)
                  SwitchListTile(
                    key: const Key('shopper-marketing-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Offers and news from Reebaplus',
                      style: context.regularStyle(14),
                    ),
                    subtitle: Text(
                      'Off unless you turn it on. Order updates always come '
                      'through.',
                      style: context.regularStyle(12).copyWith(color: muted),
                    ),
                    value: details.marketingOptIn,
                    onChanged: (v) => _setMarketing(context, ref, v),
                  ),
                SizedBox(height: context.getRSize(8)),
                AppButton(
                  key: const Key('shopper-download-data'),
                  text: 'Download my data',
                  icon: AppIcons.download,
                  variant: AppButtonVariant.outline,
                  onPressed: () => _download(context, ref),
                ),
                SizedBox(height: context.getRSize(8)),
                AppButton(
                  key: const Key('shopper-delete-account'),
                  text: 'Delete account',
                  icon: AppIcons.deleteForever,
                  variant: AppButtonVariant.danger,
                  onPressed: () => _deleteAccount(context, ref),
                ),
              ],
            ),
          ),
          AppButton(
            key: const Key('shopper-my-orders'),
            text: 'My orders',
            icon: AppIcons.orders,
            variant: AppButtonVariant.outline,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const MyOrdersScreen()),
            ),
          ),
          if (session.canSignOut) ...[
            SizedBox(height: context.getRSize(12)),
            AppButton(
              key: const Key('shopper-sign-out'),
              text: 'Sign out',
              icon: AppIcons.logout,
              variant: AppButtonVariant.ghost,
              onPressed: () => _signOut(context, ref),
            ),
          ],
        ],
      ),
    );
  }
}
