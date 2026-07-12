-- ============================================================
-- Alpha voice memos — Storage bucket + RLS
-- ============================================================
-- Run this in the Supabase SQL Editor, same as 0001-0005.
--
-- Mirrors the journal-images bucket pattern exactly (0001_rls_policies.sql,
-- "Storage: journal-images bucket" section): private bucket, owner-only
-- access gated on the first path segment matching auth.uid(). Path
-- convention (from the client, see alphaUploadVoiceMemo() in
-- index.html): "<user_id>/<entry_id>.enc".
--
-- The audio itself is ALREADY CIPHERTEXT before it ever reaches this
-- bucket — encrypted client-side with the same AES-256-GCM session key
-- as everything else in Alpha (see alphaEncryptBlob() in index.html)
-- before upload. This bucket-level privacy (own-row-only) is a second,
-- independent layer on top of that, not a substitute for it — even
-- someone who somehow bypassed RLS would only get ciphertext bytes,
-- not audio.
-- ============================================================

insert into storage.buckets (id, name, public)
values ('alpha-voice-notes', 'alpha-voice-notes', false)
on conflict (id) do nothing;

drop policy if exists "alpha_voice_notes_owner_all" on storage.objects;
create policy "alpha_voice_notes_owner_all"
  on storage.objects for all
  using (
    bucket_id = 'alpha-voice-notes'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'alpha-voice-notes'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
