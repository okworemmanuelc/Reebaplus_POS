import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'area_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AreaLocalizations
/// returned by `AreaLocalizations.of(context)`.
///
/// Applications need to include `AreaLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/area_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AreaLocalizations.localizationsDelegates,
///   supportedLocales: AreaLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AreaLocalizations.supportedLocales
/// property.
abstract class AreaLocalizations {
  AreaLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AreaLocalizations? of(BuildContext context) {
    return Localizations.of<AreaLocalizations>(context, AreaLocalizations);
  }

  static const LocalizationsDelegate<AreaLocalizations> delegate =
      _AreaLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// No description provided for @areaChoose.
  ///
  /// In en, this message translates to:
  /// **'Choose an area'**
  String get areaChoose;

  /// No description provided for @areaHelp.
  ///
  /// In en, this message translates to:
  /// **'Choose a state, then a local government area.'**
  String get areaHelp;

  /// No description provided for @areaCountry.
  ///
  /// In en, this message translates to:
  /// **'Country'**
  String get areaCountry;

  /// No description provided for @areaState.
  ///
  /// In en, this message translates to:
  /// **'State / region'**
  String get areaState;

  /// No description provided for @areaLga.
  ///
  /// In en, this message translates to:
  /// **'Local government / district'**
  String get areaLga;

  /// No description provided for @areaSearchCountry.
  ///
  /// In en, this message translates to:
  /// **'Search or enter a country'**
  String get areaSearchCountry;

  /// No description provided for @areaSearchState.
  ///
  /// In en, this message translates to:
  /// **'Search states'**
  String get areaSearchState;

  /// No description provided for @areaSearchLga.
  ///
  /// In en, this message translates to:
  /// **'Search local government areas'**
  String get areaSearchLga;

  /// No description provided for @areaWholeState.
  ///
  /// In en, this message translates to:
  /// **'Whole state'**
  String get areaWholeState;

  /// No description provided for @areaWholeStateHelp.
  ///
  /// In en, this message translates to:
  /// **'Includes every local government area in this state'**
  String get areaWholeStateHelp;

  /// No description provided for @areaNoMatches.
  ///
  /// In en, this message translates to:
  /// **'No areas found. Try a different spelling.'**
  String get areaNoMatches;

  /// No description provided for @areaUseCountry.
  ///
  /// In en, this message translates to:
  /// **'Use this country'**
  String get areaUseCountry;

  /// No description provided for @areaUse.
  ///
  /// In en, this message translates to:
  /// **'Use this area'**
  String get areaUse;

  /// No description provided for @areaFreeTextHelp.
  ///
  /// In en, this message translates to:
  /// **'Enter your state and district for this country.'**
  String get areaFreeTextHelp;

  /// No description provided for @areaRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a value'**
  String get areaRequired;

  /// No description provided for @areaClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get areaClose;

  /// No description provided for @areaChangeCountry.
  ///
  /// In en, this message translates to:
  /// **'Change country'**
  String get areaChangeCountry;

  /// No description provided for @areaChangeState.
  ///
  /// In en, this message translates to:
  /// **'Change state'**
  String get areaChangeState;
}

class _AreaLocalizationsDelegate
    extends LocalizationsDelegate<AreaLocalizations> {
  const _AreaLocalizationsDelegate();

  @override
  Future<AreaLocalizations> load(Locale locale) {
    return SynchronousFuture<AreaLocalizations>(
      lookupAreaLocalizations(locale),
    );
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AreaLocalizationsDelegate old) => false;
}

AreaLocalizations lookupAreaLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AreaLocalizationsEn();
  }

  throw FlutterError(
    'AreaLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
