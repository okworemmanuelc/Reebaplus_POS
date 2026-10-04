import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Central icon registry for the app.
///
/// Maps semantic app icon names to Material Symbols Outlined (w400).
abstract final class AppIcons {
  // --- Navigation ---
  static const IconData arrowBack = Symbols.arrow_back;
  static const IconData arrowBackIos = Symbols.arrow_back_ios;
  static const IconData arrowBackIosNew = Symbols.arrow_back_ios_new;
  static const IconData arrowDown = Symbols.arrow_downward;
  static const IconData arrowUp = Symbols.arrow_upward;
  static const IconData chevronDown = Symbols.expand_more;
  static const IconData chevronRight = Symbols.chevron_right;
  static const IconData chevronUp = Symbols.expand_less;
  static const IconData close = Symbols.close;
  static const IconData home = Symbols.dashboard;
  static const IconData keyboardArrowDown = Symbols.keyboard_arrow_down;
  static const IconData keyboardArrowUp = Symbols.keyboard_arrow_up;
  static const IconData keyboardDoubleArrowDown =
      Symbols.keyboard_double_arrow_down;
  static const IconData location = Symbols.location_on;
  static const IconData menu = Symbols.menu;
  static const IconData moreVertical = Symbols.more_vert;

  // --- Commerce ---
  static const IconData balance = Symbols.scale;
  static const IconData bank = Symbols.account_balance;
  static const IconData bill = Symbols.request_quote;
  static const IconData cart = Symbols.shopping_cart;
  static const IconData cartAdd = Symbols.add_shopping_cart;
  static const IconData cash = Symbols.payments;
  static const IconData creditBalance = Symbols.account_balance_wallet;
  static const IconData creditCard = Symbols.credit_card;
  static const IconData deposit = Symbols.savings;
  static const IconData discount = Symbols.confirmation_number;
  static const IconData expenses = Symbols.payments;
  static const IconData invoice = Symbols.receipt;
  static const IconData localGroceryStore = Symbols.local_grocery_store;
  static const IconData moneyBag = Symbols.savings;
  static const IconData naira = Symbols.payments;
  static const IconData orders = Symbols.receipt_long;
  static const IconData payments = Symbols.payments;
  static const IconData pos = Symbols.point_of_sale;
  static const IconData price = Symbols.attach_money;
  static const IconData profit = Symbols.trending_up;
  static const IconData receipt = Symbols.receipt;
  static const IconData settlement = Symbols.payments;
  static const IconData tag = Symbols.sell;
  static const IconData transfer = Symbols.sync_alt;

  // --- Inventory ---
  static const IconData acUnit = Symbols.ac_unit;
  static const IconData barcode = Symbols.barcode_scanner;
  static const IconData category = Symbols.category;
  static const IconData checkroom = Symbols.checkroom;
  static const IconData crates = Symbols.deployed_code;
  static const IconData foundation = Symbols.foundation;
  static const IconData inventory = Symbols.inventory_2;
  static const IconData localBar = Symbols.local_bar;
  static const IconData localPharmacy = Symbols.local_pharmacy;
  static const IconData manufacturer = Symbols.factory;
  static const IconData receiving = Symbols.local_shipping;
  static const IconData restaurant = Symbols.restaurant;
  static const IconData smartphone = Symbols.smartphone;
  static const IconData stockAdjustment = Symbols.inventory_2;
  static const IconData supplier = Symbols.local_shipping;
  static const IconData supplierDelivery = Symbols.local_shipping;
  static const IconData vanDelivery = Symbols.local_shipping;
  static const IconData warehouse = Symbols.warehouse;

  // --- Status ---
  static const IconData alertCircle = Symbols.error;
  static const IconData analytics = Symbols.trending_up;
  static const IconData announcement = Symbols.campaign;
  static const IconData auditCheck = Symbols.fact_check;
  static const IconData block = Symbols.block;
  static const IconData calendarCancel = Symbols.event_busy;
  static const IconData calendarCheck = Symbols.event_available;
  static const IconData cancelCircle = Symbols.cancel;
  static const IconData chartPie = Symbols.pie_chart;
  static const IconData check = Symbols.check;
  static const IconData checkCircle = Symbols.check_circle;
  static const IconData checkDouble = Symbols.done_all;
  static const IconData circle = Symbols.circle;
  static const IconData cloudOff = Symbols.cloud_off;
  static const IconData cloudSync = Symbols.cloud_sync;
  static const IconData damaged = Symbols.heart_broken;
  static const IconData ghost = Symbols.sentiment_dissatisfied;
  static const IconData goal = Symbols.flag_circle;
  static const IconData infoCircle = Symbols.info;
  static const IconData pending = Symbols.hourglass_top;
  static const IconData premium = Symbols.workspace_premium;
  static const IconData syncIssues = Symbols.cloud_upload;
  static const IconData target = Symbols.adjust;
  static const IconData voteCheck = Symbols.how_to_vote;
  static const IconData waiting = Symbols.hourglass_empty;
  static const IconData warning = Symbols.warning;

  // --- Actions ---
  static const IconData add = Symbols.add;
  static const IconData addCircle = Symbols.add_circle;
  static const IconData addSquare = Symbols.add_box;
  static const IconData attachment = Symbols.attach_file;
  static const IconData backspace = Symbols.backspace;
  static const IconData biometrics = Symbols.fingerprint;
  static const IconData camera = Symbols.photo_camera;
  static const IconData checkBox = Symbols.check_box;
  static const IconData checkBoxOutlineBlank = Symbols.check_box_outline_blank;
  static const IconData clearFilter = Symbols.filter_alt_off;
  static const IconData copy = Symbols.content_copy;
  static const IconData delete = Symbols.delete;
  static const IconData deleteForever = Symbols.delete_forever;
  static const IconData download = Symbols.cloud_download;
  static const IconData edit = Symbols.edit;
  static const IconData export = Symbols.file_export;
  static const IconData exportFile = Symbols.upload_file;
  static const IconData fileApproved = Symbols.file_open;
  static const IconData flashOff = Symbols.flash_off;
  static const IconData flashOn = Symbols.flash_on;
  static const IconData image = Symbols.image;
  static const IconData link = Symbols.link;
  static const IconData lock = Symbols.lock;
  static const IconData logout = Symbols.logout;
  static const IconData magic = Symbols.auto_fix_high;
  static const IconData minus = Symbols.remove;
  static const IconData noPhotography = Symbols.no_photography;
  static const IconData play = Symbols.play_arrow;
  static const IconData print = Symbols.print;
  static const IconData radioButtonChecked = Symbols.radio_button_checked;
  static const IconData radioButtonUnchecked = Symbols.radio_button_unchecked;
  static const IconData recycle = Symbols.recycling;
  static const IconData refresh = Symbols.refresh;
  static const IconData removeCircle = Symbols.remove_circle;
  static const IconData rocket = Symbols.rocket_launch;
  static const IconData rotate = Symbols.autorenew;
  static const IconData save = Symbols.save;
  static const IconData search = Symbols.search;
  static const IconData send = Symbols.send;
  static const IconData share = Symbols.share;
  static const IconData swap = Symbols.swap_horiz;
  static const IconData sync = Symbols.sync;
  static const IconData undo = Symbols.replay;
  static const IconData update = Symbols.update;
  static const IconData visibility = Symbols.visibility;
  static const IconData zoomOut = Symbols.zoom_out;

  // --- People ---
  static const IconData adminPanel = Symbols.admin_panel_settings;
  static const IconData customerRole = Symbols.person;
  static const IconData customers = Symbols.group;
  static const IconData driver = Symbols.two_wheeler;
  static const IconData idBadge = Symbols.badge;
  static const IconData managerRole = Symbols.person;
  static const IconData owner = Symbols.crown;
  static const IconData personSearch = Symbols.person_search;
  static const IconData staff = Symbols.badge;
  static const IconData user = Symbols.person;
  static const IconData userAdd = Symbols.person_add;
  static const IconData userEdit = Symbols.person_edit;
  static const IconData userPermissions = Symbols.shield_person;
  static const IconData userRemove = Symbols.person_remove;
  static const IconData userSettings = Symbols.manage_accounts;
  static const IconData userSuspended = Symbols.person_off;
  static const IconData userVerified = Symbols.person_check;

  // --- Settings ---
  static const IconData building = Symbols.apartment;
  static const IconData business = Symbols.business;
  static const IconData calendar = Symbols.calendar_today;
  static const IconData calendarMonth = Symbols.calendar_month;
  static const IconData clipboardList = Symbols.assignment;
  static const IconData counter = Symbols.tag;
  static const IconData darkMode = Symbols.dark_mode;
  static const IconData description = Symbols.notes;
  static const IconData divide = Symbols.percent;
  static const IconData document = Symbols.description;
  static const IconData email = Symbols.mail;
  static const IconData event = Symbols.event;
  static const IconData fileCsv = Symbols.csv;
  static const IconData flag = Symbols.flag;
  static const IconData fuel = Symbols.local_gas_station;
  static const IconData grid = Symbols.grid_view;
  static const IconData history = Symbols.history;
  static const IconData key = Symbols.key;
  static const IconData lightMode = Symbols.light_mode;
  static const IconData list = Symbols.format_list_bulleted;
  static const IconData lockClock = Symbols.lock_clock;
  static const IconData maintenance = Symbols.build;
  static const IconData map = Symbols.map;
  static const IconData notification = Symbols.notifications;
  static const IconData notificationOff = Symbols.notifications_off;
  static const IconData palette = Symbols.palette;
  static const IconData pharmacy = Symbols.pill;
  static const IconData phone = Symbols.call;
  static const IconData public = Symbols.public;
  static const IconData settings = Symbols.settings;
  static const IconData sms = Symbols.sms;
  static const IconData store = Symbols.store;
  static const IconData storefront = Symbols.storefront;
  static const IconData table = Symbols.table_chart;
  static const IconData terminal = Symbols.desktop_windows;
  static const IconData terms = Symbols.contract;
  static const IconData themeMode = Symbols.brightness_6;
  static const IconData time = Symbols.schedule;
  static const IconData whatsapp = Symbols.chat;

  // --- Product tiles ---
  static const IconData beerMug = Symbols.sports_bar;
  static const IconData box = Symbols.package_2;
  static const IconData quickSale = Symbols.bolt;
  static const IconData wineBottle = Symbols.wine_bar;

  // --- Brand ---
  // TODO(#346): replace with an SVG asset when font_awesome_flutter is removed after Wave 2.
  static const IconData googleBrand = IconData(
    0xf1a0,
    fontFamily: 'FontAwesomeBrands',
    fontPackage: 'font_awesome_flutter',
  );
}

/// Helper widget to render an [IconData] using Material Symbols w400,
/// with support for the filled axis when active/selected.
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.filled = false,
    this.semanticLabel,
  });

  final IconData? icon;
  final double? size;
  final Color? color;
  final bool filled;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Icon(
      icon,
      size: size,
      color: color,
      fill: filled ? 1.0 : 0.0,
      weight: 400.0,
      semanticLabel: semanticLabel,
    );
  }
}
