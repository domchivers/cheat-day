-- Editing your own chat message after it's sent.
-- Until now only the person a message was sent to could change its row (to mark it seen). This lets the sender
-- change it too, so the app can save new words and mark it edited (payload.edited).
-- Safe to run more than once.
drop policy if exists "messages edit" on public.messages;
create policy "messages edit" on public.messages for update to authenticated
  using (from_user = auth.uid()) with check (from_user = auth.uid());
