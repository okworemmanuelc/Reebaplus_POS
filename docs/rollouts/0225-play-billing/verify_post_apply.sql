-- Read-only post-apply checks for 0225. Every row should show ok = true.
SELECT 'table exists' AS check,
       to_regclass('public.play_subscription_purchases') IS NOT NULL AS ok
UNION ALL
SELECT 'rls forced',
       (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class
         WHERE oid = 'public.play_subscription_purchases'::regclass)
UNION ALL
SELECT 'authenticated has no write grants',
       NOT EXISTS (SELECT 1 FROM information_schema.role_table_grants
                    WHERE table_name = 'play_subscription_purchases'
                      AND grantee = 'authenticated'
                      AND privilege_type <> 'SELECT')
UNION ALL
SELECT 'apply fn is service_role only',
       has_function_privilege('service_role',
         'public.apply_play_purchase(uuid,text,text,text,timestamptz)', 'EXECUTE')
       AND NOT has_function_privilege('authenticated',
         'public.apply_play_purchase(uuid,text,text,text,timestamptz)', 'EXECUTE')
UNION ALL
SELECT '0224 present (billing_cycle column)',
       EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_name = 'businesses' AND column_name = 'billing_cycle');
