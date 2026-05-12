/// Client wrapper around the five invite Edge Functions.
///
/// Mirrors the server-side error catalog from supabase/functions/_shared/errors.ts;
/// keep the two enums in sync.
library;

import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/utils/logger.dart';

/// Wire-level error codes returned by the Edge Functions.
enum InviteErrorCode {
  unauthenticated,
  forbidden,
  invalidPayload,
  invalidEmail,
  disposableEmail,
  selfInvite,
  alreadyMember,
  invitePending,
  otherBusinessOwner,
  invalidWarehouse,
  forbiddenRole,
  rateLimited,
  invalidToken,
  expired,
  revoked,
  alreadyUsed,
  emailMismatch,
  extensionCapReached,
  memberNotFound,
  invalidExtraDays,
  reasonRequired,
  internal,
  networkError;

  /// Default user-facing message. Override per-screen if a more specific
  /// phrasing is needed.
  String get defaultMessage => switch (this) {
        InviteErrorCode.unauthenticated => 'Please sign in again.',
        InviteErrorCode.forbidden =>
          'Only managers and owners can send invitations.',
        InviteErrorCode.invalidPayload =>
          'Some details are missing. Please try again.',
        InviteErrorCode.invalidEmail => 'Enter a valid email address.',
        InviteErrorCode.disposableEmail =>
          "Disposable email addresses aren't allowed.",
        InviteErrorCode.selfInvite => "You can't invite yourself.",
        InviteErrorCode.alreadyMember =>
          'This person is already on your team.',
        InviteErrorCode.invitePending =>
          'An invite to this email is already pending.',
        InviteErrorCode.otherBusinessOwner =>
          'This email belongs to the owner of another business.',
        InviteErrorCode.invalidWarehouse =>
          'Pick a warehouse from your business.',
        InviteErrorCode.forbiddenRole =>
          "You can't invite someone as CEO.",
        InviteErrorCode.rateLimited =>
          'Too many invites today. Try again tomorrow.',
        InviteErrorCode.invalidToken => 'This invite link is invalid.',
        InviteErrorCode.expired =>
          'This invite has expired. Ask your manager for a new one.',
        InviteErrorCode.revoked => 'This invite has been cancelled.',
        InviteErrorCode.alreadyUsed =>
          'This invite has already been used.',
        InviteErrorCode.emailMismatch =>
          'This invite was sent to a different email.',
        InviteErrorCode.extensionCapReached =>
          "This staff member has already had two extensions — they can't get another.",
        InviteErrorCode.memberNotFound =>
          "We couldn't find that staff member.",
        InviteErrorCode.invalidExtraDays =>
          'Pick a number of days between 1 and 30.',
        InviteErrorCode.reasonRequired =>
          'Add a short reason for the extension.',
        InviteErrorCode.internal => 'Something went wrong. Please try again.',
        InviteErrorCode.networkError =>
          "Couldn't reach the server. Check your connection.",
      };

  static InviteErrorCode? fromWire(String? wire) {
    if (wire == null) return null;
    return switch (wire) {
      'unauthenticated' => InviteErrorCode.unauthenticated,
      'forbidden' => InviteErrorCode.forbidden,
      'invalid_payload' => InviteErrorCode.invalidPayload,
      'invalid_email' => InviteErrorCode.invalidEmail,
      'disposable_email' => InviteErrorCode.disposableEmail,
      'self_invite' => InviteErrorCode.selfInvite,
      'already_member' => InviteErrorCode.alreadyMember,
      'invite_pending' => InviteErrorCode.invitePending,
      'other_business_owner' => InviteErrorCode.otherBusinessOwner,
      'invalid_warehouse' => InviteErrorCode.invalidWarehouse,
      'forbidden_role' => InviteErrorCode.forbiddenRole,
      'rate_limited' => InviteErrorCode.rateLimited,
      'invalid_token' => InviteErrorCode.invalidToken,
      'expired' => InviteErrorCode.expired,
      'revoked' => InviteErrorCode.revoked,
      'already_used' => InviteErrorCode.alreadyUsed,
      'email_mismatch' => InviteErrorCode.emailMismatch,
      'extension_cap_reached' => InviteErrorCode.extensionCapReached,
      'member_not_found' => InviteErrorCode.memberNotFound,
      'invalid_extra_days' => InviteErrorCode.invalidExtraDays,
      'reason_required' => InviteErrorCode.reasonRequired,
      'internal' => InviteErrorCode.internal,
      _ => null,
    };
  }
}

/// Result wrapper for every Edge-Function call.
sealed class InviteApiResult<T> {
  const InviteApiResult();
}

class InviteApiOk<T> extends InviteApiResult<T> {
  final T data;
  const InviteApiOk(this.data);
}

class InviteApiErr<T> extends InviteApiResult<T> {
  final InviteErrorCode code;
  final String message;
  final Map<String, dynamic>? details;
  const InviteApiErr(this.code, this.message, [this.details]);
}

class InviteApiService {
  final SupabaseClient _supabase;

  InviteApiService(this._supabase);

  /// Generic invoker that maps both successful and error responses onto
  /// `InviteApiResult`. Handles both transport models supabase_flutter has
  /// shipped: throwing FunctionException on non-2xx (older), or returning
  /// FunctionResponse with status set (newer).
  Future<InviteApiResult<Map<String, dynamic>>> _invoke(
    String fn,
    Map<String, dynamic> body,
  ) async {
    try {
      final res = await _supabase.functions.invoke(fn, body: body);
      return _interpret(res.status, res.data);
    } on FunctionException catch (e) {
      return _interpret(e.status, e.details);
    } on SocketException catch (e, st) {
      AppLogger.error('Invite Edge Function $fn: socket error', e, st);
      return InviteApiErr(
        InviteErrorCode.networkError,
        InviteErrorCode.networkError.defaultMessage,
      );
    } on TimeoutException catch (e, st) {
      AppLogger.error('Invite Edge Function $fn: timeout', e, st);
      return InviteApiErr(
        InviteErrorCode.networkError,
        InviteErrorCode.networkError.defaultMessage,
      );
    } catch (e, st) {
      AppLogger.error('Invite Edge Function $fn: unexpected error', e, st);
      return InviteApiErr(
        InviteErrorCode.internal,
        InviteErrorCode.internal.defaultMessage,
        {'exception': e.toString()},
      );
    }
  }

  InviteApiResult<Map<String, dynamic>> _interpret(int status, dynamic data) {
    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      if (map['ok'] == true && status >= 200 && status < 300) {
        return InviteApiOk(map);
      }
      final wireCode = map['error']?.toString();
      final code = InviteErrorCode.fromWire(wireCode) ??
          InviteErrorCode.internal;
      final message = map['message']?.toString() ?? code.defaultMessage;
      final details = map['details'] is Map
          ? Map<String, dynamic>.from(map['details'] as Map)
          : null;
      return InviteApiErr(code, message, details);
    }
    return InviteApiErr(
      InviteErrorCode.internal,
      InviteErrorCode.internal.defaultMessage,
    );
  }

  // ── Step-1 modal validation ────────────────────────────────────────────
  Future<InviteApiResult<Map<String, dynamic>>> checkEmail(String email) {
    return _invoke('check-invite-email', {'email': email});
  }

  // ── Step-2 modal: create the invite. Returns {invite_id, human_code,
  //    expires_at}. Admin shares the code via WhatsApp / SMS / Email /
  //    paper from the modal success screen — no server-side dispatch.
  Future<InviteApiResult<Map<String, dynamic>>> sendInvite({
    required String email,
    required String role,
    String? warehouseId,
  }) {
    return _invoke('send-invite', {
      'email': email,
      'role': role,
      'warehouse_id': warehouseId,
    });
  }

  // ── Regenerate the human_code on an unredeemed invite. Revokes the old
  //    row and mints a fresh code with regenerated_from set. Wraps the
  //    resend-invite Edge Function (which is now a thin wrapper around
  //    the regenerate_invite_code RPC). Returns {invite_id, human_code,
  //    expires_at} for the new row.
  Future<InviteApiResult<Map<String, dynamic>>> regenerateInvite(
    String inviteId,
  ) {
    return _invoke('resend-invite', {'invite_id': inviteId});
  }

  /// Backwards-compatible alias for callers still on the old name.
  Future<InviteApiResult<Map<String, dynamic>>> resendInvite(String inviteId) {
    return regenerateInvite(inviteId);
  }

  // ── Preview before redemption (deep-link landing screen) ───────────────
  Future<InviteApiResult<Map<String, dynamic>>> previewByToken(String token) {
    return _invoke('accept-invite', {'token': token});
  }

  Future<InviteApiResult<Map<String, dynamic>>> previewByCode(String code) {
    return _invoke('accept-invite', {'code': code});
  }

  // 6-char human_code preview (Phase 2). Distinct from the 8-char `code`.
  Future<InviteApiResult<Map<String, dynamic>>> previewByHumanCode(
    String humanCode,
  ) {
    return _invoke('accept-invite', {'human_code': humanCode});
  }

  // ── Atomic finalisation (creates user + business_members, marks invite
  //    accepted). Returns canonical {user, membership, invite} which the
  //    InviteLandingScreen routes through SyncService._applyDomainResponse.
  Future<InviteApiResult<Map<String, dynamic>>> redeemByToken({
    required String token,
    required String userName,
  }) {
    return _invoke('redeem-invite', {
      'token': token,
      'user_name': userName,
    });
  }

  Future<InviteApiResult<Map<String, dynamic>>> redeemByCode({
    required String code,
    required String userName,
  }) {
    return _invoke('redeem-invite', {
      'code': code,
      'user_name': userName,
    });
  }

  Future<InviteApiResult<Map<String, dynamic>>> redeemByHumanCode({
    required String humanCode,
    required String userName,
    required String staffPhone,
    required String nextOfKinName,
    required String nextOfKinPhone,
    required String nextOfKinRelation,
    String? guarantorName,
    String? guarantorPhone,
    String? guarantorRelation,
  }) {
    return _invoke('redeem-invite', {
      'human_code': humanCode,
      'user_name': userName,
      'staff_phone': staffPhone,
      'next_of_kin_name': nextOfKinName,
      'next_of_kin_phone': nextOfKinPhone,
      'next_of_kin_relation': nextOfKinRelation,
      'guarantor_name': guarantorName,
      'guarantor_phone': guarantorPhone,
      'guarantor_relation': guarantorRelation,
    });
  }

  // ── Extend a staff member's verification deadline. Direct RPC (no Edge
  //    Function) — `extend_verification` is SECURITY DEFINER and validates
  //    the caller. Capped at 2 prior extensions; raises
  //    `extension_cap_reached` past that.
  Future<InviteApiResult<Map<String, dynamic>>> extendVerification({
    required String membershipId,
    required int extraDays,
    required String reason,
  }) async {
    try {
      final res = await _supabase.rpc('extend_verification', params: {
        'p_membership_id': membershipId,
        'p_extra_days': extraDays,
        'p_reason': reason,
      });
      if (res is Map) {
        return InviteApiOk(Map<String, dynamic>.from(res));
      }
      return const InviteApiOk(<String, dynamic>{});
    } on PostgrestException catch (e, st) {
      AppLogger.error('extend_verification RPC failed: ${e.message}', e, st);
      final code = _mapRpcExceptionToCode(e.message);
      return InviteApiErr(code, code.defaultMessage);
    } on SocketException catch (e, st) {
      AppLogger.error('extend_verification: socket error', e, st);
      return InviteApiErr(
        InviteErrorCode.networkError,
        InviteErrorCode.networkError.defaultMessage,
      );
    } on TimeoutException catch (e, st) {
      AppLogger.error('extend_verification: timeout', e, st);
      return InviteApiErr(
        InviteErrorCode.networkError,
        InviteErrorCode.networkError.defaultMessage,
      );
    } catch (e, st) {
      AppLogger.error('extend_verification: unexpected error', e, st);
      return InviteApiErr(
        InviteErrorCode.internal,
        InviteErrorCode.internal.defaultMessage,
        {'exception': e.toString()},
      );
    }
  }

  // PostgrestException.message contains the RAISE EXCEPTION text. Map the
  // few we care about; everything else is `internal`.
  InviteErrorCode _mapRpcExceptionToCode(String message) {
    final m = message.toLowerCase();
    if (m.contains('extension_cap_reached')) {
      return InviteErrorCode.extensionCapReached;
    }
    if (m.contains('member_not_found')) return InviteErrorCode.memberNotFound;
    if (m.contains('invalid_extra_days')) {
      return InviteErrorCode.invalidExtraDays;
    }
    if (m.contains('reason_required')) return InviteErrorCode.reasonRequired;
    if (m.contains('forbidden')) return InviteErrorCode.forbidden;
    if (m.contains('unauthenticated')) {
      return InviteErrorCode.unauthenticated;
    }
    return InviteErrorCode.internal;
  }

  // ── Cancel a pending invite. Wraps the revoke-invite Edge Function which
  //    validates role_tier ≥ 4, guards against revoking accepted invites
  //    (`already_used`), is idempotent on already-revoked rows, and writes
  //    an `invite.revoked` activity_logs entry. Returns the updated row.
  Future<InviteApiResult<Map<String, dynamic>>> revokeInvite(String inviteId) {
    return _invoke('revoke-invite', {'invite_id': inviteId});
  }
}

/// Typed wrapper over the JSONB returned by accept_invite_preview.
/// Keep parsing tolerant — the RPC may add fields in future migrations
/// and we don't want to break older clients.
class InvitePreview {
  final String inviteId;
  final String businessId;
  final String businessName;
  final String role;
  final String? warehouseId;
  final String? warehouseName;
  final String email;
  final DateTime expiresAt;
  final String inviterName;

  const InvitePreview({
    required this.inviteId,
    required this.businessId,
    required this.businessName,
    required this.role,
    required this.warehouseId,
    required this.warehouseName,
    required this.email,
    required this.expiresAt,
    required this.inviterName,
  });

  factory InvitePreview.fromMap(Map<String, dynamic> map) {
    return InvitePreview(
      inviteId: map['invite_id']?.toString() ?? '',
      businessId: map['business_id']?.toString() ?? '',
      businessName: map['business_name']?.toString() ?? 'Unknown Business',
      role: map['role']?.toString() ?? 'staff',
      warehouseId: map['warehouse_id']?.toString(),
      warehouseName: map['warehouse_name']?.toString(),
      email: map['email']?.toString() ?? '',
      expiresAt: DateTime.tryParse(map['expires_at']?.toString() ?? '') ??
          DateTime.now().add(const Duration(hours: 48)),
      inviterName: map['inviter_name']?.toString() ?? 'your manager',
    );
  }
}

