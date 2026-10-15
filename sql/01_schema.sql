-- ============================================================
-- 01_schema.sql : tables, indexes, helper functions, auth trigger, views
-- Supabase Dashboard -> SQL Editor -> New query -> paste -> Run
-- ============================================================

create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text,
  full_name   text not null default '',
  role        text not null default 'user' check (role in ('user','developer','admin')),
  is_banned   boolean not null default false,
  dev_approved boolean not null default false,   -- developers must be approved by an admin before uploading
  created_at  timestamptz not null default now()
);

-- emails listed here become admin automatically the first time they VERIFY their email (OTP login)
create table public.admin_emails (
  email text primary key
);

create table public.categories (
  id    serial primary key,
  name  text not null unique,
  slug  text not null unique
);

create table public.apps (
  id            uuid primary key default gen_random_uuid(),
  developer_id  uuid not null references public.profiles(id) on delete cascade,
  category_id   int  not null references public.categories(id),
  name          text not null check (char_length(name) between 2 and 60),
  package_name  text not null unique
                check (package_name ~ '^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$'),
  short_desc    text not null check (char_length(short_desc) <= 100),
  description   text not null,
  icon_path     text not null,
  is_suspended  boolean not null default false,
  created_at    timestamptz not null default now()
);

-- one row per uploaded APK version; approval happens at version level
create table public.app_versions (
  id            uuid primary key default gen_random_uuid(),
  app_id        uuid not null references public.apps(id) on delete cascade,
  version_name  text not null,
  version_code  int  not null check (version_code > 0),
  apk_path      text not null,
  apk_size      bigint not null,
  changelog     text,
  status        text not null default 'pending' check (status in ('pending','approved','rejected')),
  reject_reason text,
  reviewed_by   uuid references public.profiles(id),
  reviewed_at   timestamptz,
  created_at    timestamptz not null default now(),
  unique (app_id, version_code)
);

-- one download counted per (user, version)
create table public.downloads (
  id          bigint generated always as identity primary key,
  app_id      uuid not null references public.apps(id) on delete cascade,
  version_id  uuid not null references public.app_versions(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  unique (version_id, user_id)
);

create table public.reviews (
  id          uuid primary key default gen_random_uuid(),
  app_id      uuid not null references public.apps(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  rating      smallint not null check (rating between 1 and 5),
  comment     text check (char_length(comment) <= 1000),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (app_id, user_id)
);

create index on public.apps (developer_id);
create index on public.app_versions (app_id, status);
create index on public.downloads (app_id);
create index on public.reviews (app_id);

-- ---------- role helpers (security definer => safe to use inside RLS) ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'admin' and not is_banned);
$$;

create or replace function public.is_developer() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'developer' and not is_banned);
$$;

-- may this developer upload apps/versions? (admin approval required)
create or replace function public.is_approved_developer() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'developer' and dev_approved and not is_banned);
$$;

-- ---------- auto-create profile on signup (role can only be user/developer) ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    case when new.raw_user_meta_data->>'role' = 'developer' then 'developer' else 'user' end
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Promote allow-listed emails to admin, but only once the email is verified
-- (so nobody can grab an admin email by simply typing it into a form).
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

create trigger on_auth_user_confirmed
  after update of email_confirmed_at on auth.users
  for each row execute function public.handle_user_confirmed();

-- ---------- public store views (what normal users see) ----------
-- Only apps that have an approved version and are not suspended.
-- apk_path is intentionally NOT exposed here.
create or replace view public.store_apps as
select
  a.id, a.name, a.package_name, a.short_desc, a.description, a.icon_path,
  a.developer_id, p.full_name as developer_name,
  c.id as category_id, c.name as category_name, c.slug as category_slug,
  lv.id as version_id, lv.version_name, lv.version_code, lv.apk_size, lv.changelog,
  lv.created_at as updated_at, a.created_at,
  coalesce(dl.cnt, 0) as download_count,
  rv.avg_rating,
  coalesce(rv.cnt, 0) as review_count
from public.apps a
join public.categories c on c.id = a.category_id
join public.profiles   p on p.id = a.developer_id
join lateral (
  select av.* from public.app_versions av
  where av.app_id = a.id and av.status = 'approved'
  order by av.version_code desc limit 1
) lv on true
left join lateral (
  select count(*) as cnt from public.downloads d where d.app_id = a.id
) dl on true
left join lateral (
  select round(avg(r.rating)::numeric, 1) as avg_rating, count(*) as cnt
  from public.reviews r where r.app_id = a.id
) rv on true
where not a.is_suspended;

create or replace view public.app_reviews as
select r.id, r.app_id, r.rating, r.comment, r.created_at, p.full_name
from public.reviews r
join public.profiles p on p.id = r.user_id;
