// Mutable holder for everything the four-screen signup wizard collects
// before redemption. One instance lives for the duration of a single
// orchestrator run; do not reuse across attempts.
//
// Required (filled by screens 1–3):
//   • userName, staffPhone               — SignupDetailsScreen
//   • nokName, nokPhone, nokRelation     — SignupContactsScreen
//
// Optional (also SignupContactsScreen):
//   • guarantorName, guarantorPhone, guarantorRelation
//
// The orchestrator then assembles a redemption payload and calls
// InviteApiService.redeemByHumanCode at the screens-3-→-4 boundary.

import 'package:reebaplus_pos/features/invite/services/invite_api_service.dart';

class SignupWizardData {
  final InvitePreview preview;
  final String humanCode;
  final String email;

  // Pre-filled from the preview's invitee email-derived hint where possible;
  // the user can edit on screen 2.
  String userName;
  String staffPhone;

  String nokName;
  String nokPhone;
  String nokRelation;

  String? guarantorName;
  String? guarantorPhone;
  String? guarantorRelation;

  SignupWizardData({
    required this.preview,
    required this.humanCode,
    required this.email,
    this.userName = '',
    this.staffPhone = '',
    this.nokName = '',
    this.nokPhone = '',
    this.nokRelation = '',
    this.guarantorName,
    this.guarantorPhone,
    this.guarantorRelation,
  });
}
