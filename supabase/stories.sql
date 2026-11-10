-- Stories you post: a photo or video for 24 hours, with text and a food sticker, for friends only ("Close friends")
-- or friends and followers ("Your story"); and who's watched each one. Run once in the SQL Editor, after
-- followers_explore.sql. Safe to run again.

create table if not exists public.stories (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references auth.users(id) on delete cascade,
  kind text not null default 'photo' check (kind in ('photo', 'video')),
  media text not null,
  overlays jsonb not null default '[]'::jsonb,   -- text and food stickers, placed on the picture
  audience text not null default 'all' check (audience in ('friends', 'all')),
  seconds numeric,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours'
);
create index if not exists stories_owner on public.stories (owner, expires_at desc);
alter table public.stories enable row level security;
drop policy if exists "stories read" on public.stories;
drop policy if exists "stories own" on public.stories;
create policy "stories read" on public.stories for select to authenticated using (
  owner = auth.uid() or (expires_at > now() and not public.blocked_either(owner)
    and (public.is_friend(owner) or (audience = 'all' and public.is_follower(owner)))));
create policy "stories own" on public.stories for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());

create or replace function public.can_see_story(s uuid) returns boolean
language sql security definer stable as $$
  select exists (select 1 from public.stories x where x.id = s and (x.owner = auth.uid() or (x.expires_at > now()
    and not public.blocked_either(x.owner) and (public.is_friend(x.owner) or (x.audience = 'all' and public.is_follower(x.owner))))));
$$;
create or replace function public.my_story(s uuid) returns boolean
language sql security definer stable as $$
  select exists (select 1 from public.stories x where x.id = s and x.owner = auth.uid());
$$;

create table if not exists public.story_views (
  story_id uuid not null references public.stories(id) on delete cascade,
  viewer uuid not null references auth.users(id) on delete cascade,
  reaction text,
  created_at timestamptz not null default now(),
  primary key (story_id, viewer)
);
alter table public.story_views enable row level security;
drop policy if exists "story views read" on public.story_views;
drop policy if exists "story views add" on public.story_views;
drop policy if exists "story views change" on public.story_views;
create policy "story views read" on public.story_views for select to authenticated using (viewer = auth.uid() or public.my_story(story_id));
create policy "story views add" on public.story_views for insert to authenticated with check (viewer = auth.uid() and public.can_see_story(story_id));
create policy "story views change" on public.story_views for update to authenticated using (viewer = auth.uid()) with check (viewer = auth.uid());
