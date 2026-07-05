# Web auth — the per-user Supabase session is the operator

On web, a staff member signs in with their own email-OTP or Google identity, and
that Supabase session *is* the operator for the browser tab. There is no 6-digit
PIN and no "Who's working?" shared-till picker on web. RLS resolves the caller's
business scope server-side from `profiles.business_id` keyed on `auth.uid()`
(`current_user_business_ids()`), so a valid session is all the web client needs —
no custom JWT claims to populate.

The PIN and shared-till picker were deliberately *not* ported: invariant #2 says a
PIN never leaves the device and never reaches the cloud, so a browser fundamentally
cannot verify one. Sales are attributed to the logged-in user. A shared browser till
(one machine, many cashiers each re-authing) is accepted for now; a server-side
"quick-switch operator" factor is a possible later phase, and would need a new
cloud-verifiable factor — never the device PIN.
