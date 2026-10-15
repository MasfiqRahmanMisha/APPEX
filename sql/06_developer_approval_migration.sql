-- ============================================================
-- 06_developer_approval_migration.sql  (developer approval + admin allow-list)
-- ONLY for a project where you already ran 01..05 BEFORE this feature existed.
-- (A fresh install already contains all of this inside 01..04 — skip this file.)
-- 1) Developers must now be approved by an admin before they can upload.
-- 2) Admin allow-list: listed emails become admin automatically after verifying their email.
-- Safe to run more than once.
-- ============================================================

alter table public.profiles add column if not exists dev_approved boolean not null default false;

-- Existing developers are grandfathered in. Delete this line if you want to re-review them.
update public.profiles set dev_approved = true where role = 'developer';

create or replace function public.is_approved_developer() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'developer' and dev_approved and not is_banned);
$$;

-- upload permissions now require approval
drop policy if exists "dev creates apps" on public.apps;
create policy "dev creates apps" on public.apps
  for insert to authenticated with check (developer_id = auth.uid() and public.is_approved_developer());

drop policy if exists "dev uploads versions" on public.app_versions;
create policy "dev uploads versions" on public.app_versions
  for insert to authenticated with check (
    public.is_approved_developer() and exists (select 1 from public.apps a
      where a.id = app_versions.app_id and a.developer_id = auth.uid()));

drop policy if exists "dev uploads apk" on storage.objects;
create policy "dev uploads apk" on storage.objects for insert to authenticated
  with check (bucket_id = 'apks' and public.is_approved_developer()
              and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "dev uploads icon" on storage.objects;
create policy "dev uploads icon" on storage.objects for insert to authenticated
  with check (bucket_id = 'icons' and public.is_approved_developer()
              and (storage.foldername(name))[1] = auth.uid()::text);

-- admin action + dashboard counter
create or replace function public.admin_set_developer_approval(p_user_id uuid, p_flag boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  update profiles set dev_approved = p_flag where id = p_user_id and role = 'developer';
  if not found then raise exception 'Developer not found'; end if;
end $$;

revoke execute on function public.admin_set_developer_approval(uuid, boolean) from public, anon;
grant  execute on function public.admin_set_developer_approval(uuid, boolean) to authenticated;

create or replace function public.admin_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return jsonb_build_object(
    'total_apps', (select count(*) from apps),
    'live_apps', (select count(*) from apps a where not a.is_suspended
        and exists (select 1 from app_versions v where v.app_id = a.id and v.status = 'approved')),
    'suspended_apps', (select count(*) from apps where is_suspended),
    'total_downloads', (select count(*) from downloads),
    'pending_approvals', (select count(*) from app_versions where status = 'pending'),
    'total_developers', (select count(*) from profiles where role = 'developer'),
    'total_users', (select count(*) from profiles where role = 'user'),
    'pending_developers', (select count(*) from profiles where role = 'developer' and not dev_approved and not is_banned)
  );
end $$;

-- ---------------- admin allow-list ----------------
create table if not exists public.admin_emails (email text primary key);
alter table public.admin_emails enable row level security;
revoke all on public.admin_emails from anon, authenticated;

create or replace function public.handle_user_confirmed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.email_confirmed_at is not null and old.email_confirmed_at is null then
    update public.profiles set role = 'admin'
     where id = new.id
       and exists (select 1 from public.admin_emails a where lower(a.email) = lower(new.email));
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_confirmed on auth.users;
create trigger on_auth_user_confirmed
  after update of email_confirmed_at on auth.users
  for each row execute function public.handle_user_confirmed();

-- then add your admin email(s):
-- insert into public.admin_emails (email) values ('your-admin@email.com') on conflict do nothing;
