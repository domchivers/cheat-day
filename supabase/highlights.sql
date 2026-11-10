-- Highlights: stories kept on your profile after their 24 hours, in named circles, like Instagram's.
-- Each one keeps copies of its stories, so they stay when the story itself expires. Seen by the same people as your
-- posts: friends, followers, and anyone if your profile is public. Run once in the SQL Editor, after stories.sql.

create table if not exists public.highlights (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references auth.users(id) on delete cascade,
  title text not null default '',
  cover text,
  items jsonb not null default '[]'::jsonb,
  position int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists highlights_owner on public.highlights (owner, position);
alter table public.highlights enable row level security;
drop policy if exists "highlights read" on public.highlights;
drop policy if exists "highlights own" on public.highlights;
create policy "highlights read" on public.highlights for select to authenticated using (
  owner = auth.uid() or public.is_friend(owner)
  or (not public.blocked_either(owner) and (public.is_follower(owner) or public.is_public(owner))));
create policy "highlights own" on public.highlights for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
