// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'area_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AreaLocalizationsEn extends AreaLocalizations {
  AreaLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get areaChoose => 'Choose an area';

  @override
  String get areaHelp => 'Choose a state, then a local government area.';

  @override
  String get areaCountry => 'Country';

  @override
  String get areaState => 'State / region';

  @override
  String get areaLga => 'Local government / district';

  @override
  String get areaSearchCountry => 'Search or enter a country';

  @override
  String get areaSearchState => 'Search states';

  @override
  String get areaSearchLga => 'Search local government areas';

  @override
  String get areaWholeState => 'Whole state';

  @override
  String get areaWholeStateHelp =>
      'Includes every local government area in this state';

  @override
  String get areaNoMatches => 'No areas found. Try a different spelling.';

  @override
  String get areaUseCountry => 'Use this country';

  @override
  String get areaUse => 'Use this area';

  @override
  String get areaFreeTextHelp =>
      'Enter your state and district for this country.';

  @override
  String get areaRequired => 'Enter a value';

  @override
  String get areaClose => 'Close';

  @override
  String get areaChangeCountry => 'Change country';

  @override
  String get areaChangeState => 'Change state';
}
