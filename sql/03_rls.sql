-- ============================================================
-- 03_rls.sql : Row Level Security + column/function grants
-- ============================================================
alter table public.profiles     enable row level security;
alter table public.categories   enable row level security;
alter table public.apps         enable row level security;
alter table public.app_versions enable row level security;
alter table public.downloads    enable row level security;
alter table public.reviews      enable row level security;
alter table public.admin_emails enable row level security;   -- no policies => nobody can read it from the API

-- start from zero privileges, then grant exactly what is needed
revoke all on public.profiles, public.categories, public.apps, public.app_versions,
              public.downloads, public.reviews, public.admin_emails from anon, authenticated;

grant select on public.categories to anon, authenticated;
grant select on public.profiles   to authenticated;
grant update (full_name) on public.profiles to authenticated;           -- role/ban cannot be self-edited

grant select on public.apps to authenticated;
grant insert (developer_id, category_id, name, package_name, short_desc, description, icon_path)
  on public.apps to authenticated;                                      -- is_suspended not settable
grant update (category_id, name, short_desc, description, icon_path) on public.apps to authenticated;

grant select on public.app_versions to authenticated;
grant insert (app_id, version_name, version_code, apk_path, apk_size, changelog)
  on public.app_versions to authenticated;                              -- status always 'pending'

grant select on public.downloads to authenticated;                      -- inserts only via record_download()

grant select, delete on public.reviews to authenticated;
grant insert (app_id, user_id, rating, comment) on public.reviews to authenticated;
grant update (rating, comment, updated_at) on public.reviews to authenticated;

revoke all on public.store_apps, public.app_reviews from anon, authenticated;
grant select on public.store_apps, public.app_reviews to anon, authenticated;

-- ---------------- policies ----------------
create policy "categories readable" on public.categories for select using (true);

create policy "own profile or admin" on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_admin());
create policy "update own profile" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy "dev own apps or admin" on public.apps
  for select to authenticated using (developer_id = auth.uid() or public.is_admin());
create policy "dev creates apps" on public.apps
  for insert to authenticated with check (developer_id = auth.uid() and public.is_approved_developer());
create policy "dev edits own apps" on public.apps
  for update to authenticated using (developer_id = auth.uid() and public.is_developer())
  with check (developer_id = auth.uid());

create policy "dev own versions or admin" on public.app_versions
  for select to authenticated using (
    public.is_admin() or exists (select 1 from public.apps a
      where a.id = app_versions.app_id and a.developer_id = auth.uid()));
create policy "dev uploads versions" on public.app_versions
  for insert to authenticated with check (
    public.is_approved_developer() and exists (select 1 from public.apps a
      where a.id = app_versions.app_id and a.developer_id = auth.uid()));

create policy "own downloads or admin" on public.downloads
  for select to authenticated using (user_id = auth.uid() or public.is_admin());

create policy "own reviews or admin" on public.reviews
  for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy "review only after download" on public.reviews
  for insert to authenticated with check (
    user_id = auth.uid() and exists (select 1 from public.downloads d
      where d.app_id = reviews.app_id and d.user_id = auth.uid()));
create policy "edit own review" on public.reviews
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "delete own review" on public.reviews
  for delete to authenticated using (user_id = auth.uid());

-- ---------------- function grants ----------------
revoke execute on function public.record_download(uuid), public.developer_stats(), public.developer_apps(),
  public.admin_stats(), public.admin_apps(), public.admin_review_version(uuid, boolean, text),
  public.admin_set_suspended(uuid, boolean), public.admin_set_ban(uuid, boolean),
  public.admin_set_developer_approval(uuid, boolean)
  from public, anon;
grant execute on function public.record_download(uuid), public.developer_stats(), public.developer_apps(),
  public.admin_stats(), public.admin_apps(), public.admin_review_version(uuid, boolean, text),
  public.admin_set_suspended(uuid, boolean), public.admin_set_ban(uuid, boolean),
  public.admin_set_developer_approval(uuid, boolean)
  to authenticated;
