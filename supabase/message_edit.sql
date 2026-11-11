-- Editing after sending: your own chat message, and your own post's caption.
-- Safe to run more than once.

-- Messages: until now only the person a message was sent to could change its row (to mark it seen). This lets the
-- sender change it too, so the app can save new words and mark it edited (payload.edited).
drop policy if exists "messages edit" on public.messages;
create policy "messages edit" on public.messages for update to authenticated
  using (from_user = auth.uid()) with check (from_user = auth.uid());

-- Posts: the owner can change their own post (the caption). If a rule already allowed this, this one changes nothing.
drop policy if exists "posts edit" on public.posts;
create policy "posts edit" on public.posts for update to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());
