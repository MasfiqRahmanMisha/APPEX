-- ============================================================
-- 02_functions.sql : RPC functions (download counting, dashboards, admin actions)
-- ============================================================

-- Records a download (once per user+version) and returns the private APK path.
create or replace function public.record_download(p_app_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  rec record;
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Please sign in to download'; end if;
  if exists (select 1 from profiles where id = uid and is_banned) then
    raise exception 'Account is banned';
  end if;

  select av.id as version_id, av.apk_path, a.developer_id into rec
  from apps a
  join app_versions av on av.app_id = a.id and av.status = 'approved'
  where a.id = p_app_id and not a.is_suspended
  order by av.version_code desc limit 1;

  if not found then raise exception 'App not available'; end if;

  -- developers downloading their own app do not inflate the count
  if rec.developer_id <> uid then
    insert into downloads (app_id, version_id, user_id)
    values (p_app_id, rec.version_id, uid)
    on conflict (version_id, user_id) do nothing;
  end if;

  return rec.apk_path;
end $$;

-- ---------------- developer dashboard ----------------
create or replace function public.developer_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if not is_developer() then raise exception 'Developers only'; end if;
  return jsonb_build_object(
    'apps_total', (select count(*) from apps where developer_id = uid),
    'apps_launched', (select count(*) from apps a where a.developer_id = uid
        and exists (select 1 from app_versions v where v.app_id = a.id and v.status = 'approved')),
    'pending_versions', (select count(*) from app_versions v join apps a on a.id = v.app_id
        where a.developer_id = uid and v.status = 'pending'),
    'total_downloads', (select count(*) from downloads d join apps a on a.id = d.app_id
        where a.developer_id = uid),
    'overall_rating', (select round(avg(r.rating)::numeric, 2) from reviews r join apps a on a.id = r.app_id
        where a.developer_id = uid),
    'review_count', (select count(*) from reviews r join apps a on a.id = r.app_id
        where a.developer_id = uid),
    'top_app', (select to_jsonb(t) from (
        select a.id, a.name, count(d.id) as downloads
        from apps a left join downloads d on d.app_id = a.id
        where a.developer_id = uid
        group by a.id, a.name
        having count(d.id) > 0
        order by count(d.id) desc limit 1) t)
  );
end $$;

create or replace function public.developer_apps()
returns table (id uuid, name text, icon_path text, category_name text, live_version text,
               pending_versions bigint, rejected_versions bigint, downloads bigint,
               avg_rating numeric, review_count bigint, is_suspended boolean, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select a.id, a.name, a.icon_path, c.name,
    (select av.version_name from app_versions av where av.app_id = a.id and av.status = 'approved'
       order by av.version_code desc limit 1),
    (select count(*) from app_versions av where av.app_id = a.id and av.status = 'pending'),
    (select count(*) from app_versions av where av.app_id = a.id and av.status = 'rejected'),
    (select count(*) from downloads d where d.app_id = a.id),
    (select round(avg(r.rating)::numeric, 1) from reviews r where r.app_id = a.id),
    (select count(*) from reviews r where r.app_id = a.id),
    a.is_suspended, a.created_at
  from apps a join categories c on c.id = a.category_id
  where a.developer_id = auth.uid() and public.is_developer()
  order by a.created_at desc;
$$;

-- ---------------- admin dashboard ----------------
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

create or replace function public.admin_apps()
returns table (id uuid, name text, package_name text, icon_path text, developer_name text,
               category_name text, is_suspended boolean, live_version text,
               pending_versions bigint, downloads bigint, avg_rating numeric, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select a.id, a.name, a.package_name, a.icon_path, p.full_name, c.name, a.is_suspended,
    (select av.version_name from app_versions av where av.app_id = a.id and av.status = 'approved'
       order by av.version_code desc limit 1),
    (select count(*) from app_versions av where av.app_id = a.id and av.status = 'pending'),
    (select count(*) from downloads d where d.app_id = a.id),
    (select round(avg(r.rating)::numeric, 1) from reviews r where r.app_id = a.id),
    a.created_at
  from apps a
  join categories c on c.id = a.category_id
  join profiles p on p.id = a.developer_id
  where public.is_admin()
  order by a.created_at desc;
$$;

-- ---------------- admin actions ----------------
create or replace function public.admin_review_version(p_version_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if not p_approve and coalesce(trim(p_reason), '') = '' then
    raise exception 'A rejection reason is required';
  end if;
  update app_versions
     set status = case when p_approve then 'approved' else 'rejected' end,
         reject_reason = case when p_approve then null else p_reason end,
         reviewed_by = auth.uid(), reviewed_at = now()
   where id = p_version_id and status = 'pending';
  if not found then raise exception 'Version is not pending'; end if;
end $$;

create or replace function public.admin_set_suspended(p_app_id uuid, p_flag boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  update apps set is_suspended = p_flag where id = p_app_id;
end $$;

create or replace function public.admin_set_developer_approval(p_user_id uuid, p_flag boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  update profiles set dev_approved = p_flag where id = p_user_id and role = 'developer';
  if not found then raise exception 'Developer not found'; end if;
end $$;

create or replace function public.admin_set_ban(p_user_id uuid, p_flag boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  update profiles set is_banned = p_flag where id = p_user_id and role <> 'admin';
  if not found then raise exception 'User not found or is an admin'; end if;
end $$;
