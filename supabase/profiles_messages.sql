-- Profiles (a photo, @username, bio, tags, pinned badges) and one-to-one messages between friends.
-- Run once in the Supabase SQL Editor. Safe to run again.

alter table public.profiles add column if not exists username text;
alter table public.profiles add column if not exists avatar text;
alter table public.profiles add column if not exists bio text not null default '';
alter table public.profiles add column if not exists tags jsonb not null default '[]'::jsonb;
alter table public.profiles add column if not exists pinned jsonb not null default '[]'::jsonb;
alter table public.profiles add column if not exists show_week boolean not null default true;
alter table public.profiles add column if not exists seen_at timestamptz;
create unique index if not exists profiles_username_key on public.profiles (lower(username)) where username is not null;
do $$ begin
  alter table public.profiles add constraint profiles_username_format check (username is null or username ~ '^[a-z0-9._]{3,20}$');
exception when duplicate_object then null; end $$;

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  from_user uuid not null references auth.users(id) on delete cascade,
  to_user uuid not null references auth.users(id) on delete cascade,
  kind text not null default 'text',            -- text, photo, post, food
  text text not null default '',
  payload jsonb not null default '{}'::jsonb,   -- a post, a food or a photo's address
  seen_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists messages_pair on public.messages (from_user, to_user, created_at desc);
create index if not exists messages_to on public.messages (to_user, created_at desc);
alter table public.messages enable row level security;
drop policy if exists "messages read" on public.messages;
drop policy if exists "messages send" on public.messages;
drop policy if exists "messages seen" on public.messages;
drop policy if exists "messages delete" on public.messages;
create policy "messages read" on public.messages for select to authenticated using (from_user = auth.uid() or to_user = auth.uid());
create policy "messages send" on public.messages for insert to authenticated with check (from_user = auth.uid() and public.is_friend(to_user));
create policy "messages seen" on public.messages for update to authenticated using (to_user = auth.uid()) with check (to_user = auth.uid());
create policy "messages delete" on public.messages for delete to authenticated using (from_user = auth.uid());

create or replace function public.in_my_chat(m uuid) returns boolean
language sql security definer stable as $$
  select exists (select 1 from public.messages x where x.id = m and (x.from_user = auth.uid() or x.to_user = auth.uid()));
$$;

create table if not exists public.message_reactions (
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  emoji text not null,
  created_at timestamptz not null default now(),
  primary key (message_id, user_id)
);
alter table public.message_reactions enable row level security;
drop policy if exists "message reactions read" on public.message_reactions;
drop policy if exists "message reactions own" on public.message_reactions;
create policy "message reactions read" on public.message_reactions for select to authenticated using (public.in_my_chat(message_id));
create policy "message reactions own" on public.message_reactions for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid() and public.in_my_chat(message_id));

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter uuid not null references auth.users(id) on delete cascade,
  reported uuid not null references auth.users(id) on delete cascade,
  reason text not null default '',
  created_at timestamptz not null default now()
);
alter table public.reports enable row level security;
drop policy if exists "reports send" on public.reports;
create policy "reports send" on public.reports for insert to authenticated with check (reporter = auth.uid());
