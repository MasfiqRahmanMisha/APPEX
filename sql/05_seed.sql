-- ============================================================
-- 05_seed.sql : categories + how to create the first admin
-- ============================================================
insert into public.categories (name, slug) values
  ('Tools','tools'), ('Games','games'), ('Education','education'),
  ('Social','social'), ('Productivity','productivity'), ('Entertainment','entertainment'),
  ('Finance','finance'), ('Health & Fitness','health-fitness'),
  ('Photography','photography'), ('Music & Audio','music-audio')
on conflict do nothing;

-- Create the admin (easiest):
--   1) Put your admin email in the allow-list BEFORE you first sign in:
--        insert into public.admin_emails (email) values ('your-admin@email.com');
--   2) Open the site -> Register with that email + a password -> verify the emailed code (once).
--      You land on the admin dashboard automatically.
--
-- If that email already has an account, promote it manually instead:
--        update public.profiles set role = 'admin' where email = 'your-admin@email.com';
