-- Ask chats shared with the team (28 Nov), only from people who turn on Settings › Assistant › Share my chats.
-- chat_shares: one row per chat, sent again as the chat grows (the text report and the saved chat, with any photos).
-- chat_flags: a "Looks wrong?" report on one card of a chat.
-- People can add and delete their own rows and see only their own; the team reads them all here in the dashboard.
-- Photos go into the private chat-photos bucket, each person in their own folder.
-- Run once in the SQL Editor. Safe to run again.

create table if not exists public.chat_shares (
  user_id uuid not null references auth.users on delete cascade,
  chat_id text not null,
  app_version text not null default '',
  report text not null default '',
  chat jsonb not null default '{}'::jsonb,
  photos jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, chat_id)
);

create table if not exists public.chat_flags (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users on delete cascade,
  chat_id text not null,
  turn int not null default -1,
  reason text not null default '',
  note text not null default '',
  app_version text not null default '',
  created_at timestamptz not null default now(),
  foreign key (user_id, chat_id) references public.chat_shares (user_id, chat_id) on delete cascade
);

alter table public.chat_shares enable row level security;
alter table public.chat_flags enable row level security;

drop policy if exists "own chats: read" on public.chat_shares;
drop policy if exists "own chats: add" on public.chat_shares;
drop policy if exists "own chats: update" on public.chat_shares;
drop policy if exists "own chats: delete" on public.chat_shares;
create policy "own chats: read" on public.chat_shares for select to authenticated using (user_id = auth.uid());
create policy "own chats: add" on public.chat_shares for insert to authenticated with check (user_id = auth.uid());
create policy "own chats: update" on public.chat_shares for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own chats: delete" on public.chat_shares for delete to authenticated using (user_id = auth.uid());

drop policy if exists "own flags: read" on public.chat_flags;
drop policy if exists "own flags: add" on public.chat_flags;
drop policy if exists "own flags: delete" on public.chat_flags;
create policy "own flags: read" on public.chat_flags for select to authenticated using (user_id = auth.uid());
create policy "own flags: add" on public.chat_flags for insert to authenticated with check (user_id = auth.uid());
create policy "own flags: delete" on public.chat_flags for delete to authenticated using (user_id = auth.uid());

-- the photos: a private bucket (no public addresses), 5 MB a photo, each person only in their own folder
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-photos', 'chat-photos', false, 5242880, array['image/jpeg'])
on conflict (id) do update set public = false;

drop policy if exists "chat photos: add own" on storage.objects;
drop policy if exists "chat photos: read own" on storage.objects;
drop policy if exists "chat photos: delete own" on storage.objects;
create policy "chat photos: add own" on storage.objects for insert to authenticated
  with check (bucket_id = 'chat-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "chat photos: read own" on storage.objects for select to authenticated
  using (bucket_id = 'chat-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "chat photos: delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'chat-photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- to read them: the newest reports first, with the chat they're about
-- select f.created_at, f.reason, f.note, f.turn, s.app_version, s.report, s.photos
--   from public.chat_flags f join public.chat_shares s using (user_id, chat_id) order by f.created_at desc;
