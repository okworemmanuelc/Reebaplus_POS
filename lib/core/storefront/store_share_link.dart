/// Public web storefront address for one online store (#439).
const kStorefrontBaseUrl = 'https://reebaplus.com/shop/s/';

/// The link a shop owner shares so shoppers land on this store's page.
String storeShareLink(String storeId) => '$kStorefrontBaseUrl$storeId';
