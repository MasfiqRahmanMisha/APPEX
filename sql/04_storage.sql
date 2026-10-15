-- ============================================================
-- 04_storage.sql : buckets + storage policies
--   apks  = PRIVATE (download only through signed URLs)
--   icons = public  (app icons)
-- File layout:  <bucket>/<developer_uid>/<random>.<ext>
-- NOTE: Supabase Free plan caps any upload at 50 MB.
-- ============================================================
insert into storage.buckets (id, name, public, file_size_limit)
values ('apks',  'apks',  false, 52428800),
       ('icons', 'icons', true,  2097152)
on conflict (id) do nothing;

-- developers upload only into their own folder
create policy "dev uploads apk" on storage.objects for insert to authenticated
  with check (bucket_id = 'apks' and public.is_approved_developer()
              and (storage.foldername(name))[1] = auth.uid()::text);
create policy "dev uploads icon" on storage.objects for insert to authenticated
  with check (bucket_id = 'icons' and public.is_approved_developer()
              and (storage.foldername(name))[1] = auth.uid()::text);

-- developers can remove their own files (cleanup after a failed upload)
create policy "dev deletes own files" on storage.objects for delete to authenticated
  using (bucket_id in ('apks','icons') and (storage.foldername(name))[1] = auth.uid()::text);

-- reading APKs: admin, the owner, or anyone for an APPROVED version of a live app.
-- apk_path is never listed publicly; it is only returned by record_download().
create policy "apk read" on storage.objects for select to authenticated
  using (bucket_id = 'apks' and (
    public.is_admin()
    or (storage.foldername(name))[1] = auth.uid()::text
    or exists (select 1 from public.app_versions v join public.apps a on a.id = v.app_id
               where v.apk_path = storage.objects.name and v.status = 'approved' and not a.is_suspended)
  ));
