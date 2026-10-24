-- #472: service-maintained public reference; shop mappings remain tenant data.
BEGIN;
CREATE TABLE public.marketplace_categories (
  slug text PRIMARY KEY,
  name text NOT NULL,
  parent_slug text REFERENCES public.marketplace_categories(slug),
  sort integer NOT NULL,
  restricted text CHECK (restricted IN ('age_18', 'prescription'))
);
ALTER TABLE public.marketplace_categories ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.marketplace_categories FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.marketplace_categories TO anon, authenticated;
GRANT ALL ON public.marketplace_categories TO service_role;
CREATE POLICY marketplace_categories_public_read ON public.marketplace_categories
  FOR SELECT TO anon, authenticated USING (true);
INSERT INTO public.marketplace_categories (slug, name, parent_slug, sort, restricted) VALUES
  ('other', 'Other', NULL, 0, NULL),
  ('beverages', 'Beverages', NULL, 1, NULL),
  ('water', 'Water', 'beverages', 2, NULL),
  ('soft-drinks', 'Soft Drinks', 'beverages', 3, NULL),
  ('beer', 'Beer', 'beverages', 4, 'age_18'),
  ('spirits', 'Spirits', 'beverages', 5, 'age_18'),
  ('wine', 'Wine', 'beverages', 6, 'age_18'),
  ('energy-drinks', 'Energy Drinks', 'beverages', 7, NULL),
  ('health', 'Health', NULL, 8, NULL),
  ('antibiotics', 'Antibiotics', 'health', 9, NULL),
  ('painkillers', 'Painkillers', 'health', 10, NULL),
  ('vitamins', 'Vitamins', 'health', 11, NULL),
  ('antimalarials', 'Antimalarials', 'health', 12, NULL),
  ('first-aid', 'First Aid', 'health', 13, NULL),
  ('electronics', 'Electronics', NULL, 14, NULL),
  ('phones', 'Phones', 'electronics', 15, NULL),
  ('chargers', 'Chargers', 'electronics', 16, NULL),
  ('earphones', 'Earphones', 'electronics', 17, NULL),
  ('cases', 'Cases', 'electronics', 18, NULL),
  ('food', 'Food', NULL, 19, NULL),
  ('frozen-meat', 'Frozen Meat', 'food', 20, NULL),
  ('frozen-fish', 'Frozen Fish', 'food', 21, NULL),
  ('vegetables', 'Vegetables', 'food', 22, NULL),
  ('dairy', 'Dairy', 'food', 23, NULL),
  ('groceries', 'Groceries', 'food', 24, NULL),
  ('snacks', 'Snacks', 'food', 25, NULL),
  ('meals', 'Meals', NULL, 26, NULL),
  ('starters', 'Starters', 'meals', 27, NULL),
  ('main-dishes', 'Main Dishes', 'meals', 28, NULL),
  ('drinks', 'Drinks', 'meals', 29, NULL),
  ('desserts', 'Desserts', 'meals', 30, NULL),
  ('household', 'Household', NULL, 31, NULL),
  ('toiletries', 'Toiletries', 'household', 32, NULL),
  ('building-materials', 'Building Materials', NULL, 33, NULL),
  ('cement', 'Cement', 'building-materials', 34, NULL),
  ('blocks', 'Blocks', 'building-materials', 35, NULL),
  ('steel', 'Steel', 'building-materials', 36, NULL),
  ('paint', 'Paint', 'building-materials', 37, NULL),
  ('plumbing', 'Plumbing', 'building-materials', 38, NULL),
  ('fashion', 'Fashion', NULL, 39, NULL),
  ('men', 'Men', 'fashion', 40, NULL),
  ('women', 'Women', 'fashion', 41, NULL),
  ('kids', 'Kids', 'fashion', 42, NULL),
  ('footwear', 'Footwear', 'fashion', 43, NULL),
  ('phone-accessories', 'Phone accessories', 'electronics', 44, NULL),
  ('fashion-accessories', 'Fashion accessories', 'fashion', 45, NULL);
ALTER TABLE public.categories ADD COLUMN marketplace_category text
  REFERENCES public.marketplace_categories(slug);
-- pos_pull_snapshot already selects to_jsonb(t) for categories: the new
-- column is included automatically, for both full and incremental snapshots.
COMMIT;
