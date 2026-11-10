-- Followers (one-way, approved when your profile is private), blocking, and Explore (public profiles' posts).
-- Run once in the Supabase SQL Editor, after profiles_messages.sql. Safe to run again.

alter table public.profiles add column if not exists private boolean not null default true;
alter table public.profiles add column if not exists privacy_chosen boolean not null default false;

create table if not exists public.follows (
  follower uuid not null references auth.users(id) on delete cascade,
  followee uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  primary key (follower, followee),
  check (follower <> followee)
);
create index if not exists follows_followee on public.follows (followee, status);

create table if not exists public.blocks (
  blocker uuid not null references auth.users(id) on delete cascade,
  blocked uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked)
);
alter table public.blocks enable row level security;
drop policy if exists "blocks own" on public.blocks;
create policy "blocks own" on public.blocks for all to authenticated using (blocker = auth.uid()) with check (blocker = auth.uid());

create or replace function public.is_public(u uuid) returns boolean
language sql security definer stable as $$
  select exists (select 1 from public.profiles p where p.user_id = u and p.private = false);
$$;

create or replace function public.blocked_either(u uuid) returns boolean
language sql security definer stable as $$
  select exists (select 1 from public.blocks b where (b.blocker = u and b.blocked = auth.uid()) or (b.blocker = auth.uid() and b.blocked = u));
$$;

create or replace function public.is_follower(owner uuid) returns boolean
language sql security definer stable as $$
  select exists (select 1 from public.follows f where f.follower = auth.uid() and f.followee = owner and f.status = 'accepted');
$$;

alter table public.follows enable row level security;
drop policy if exists "follows see" on public.follows;
drop policy if exists "follows ask" on public.follows;
drop policy if exists "follows accept" on public.follows;
drop policy if exists "follows remove" on public.follows;
create policy "follows see" on public.follows for select to authenticated using (follower = auth.uid() or followee = auth.uid());
-- straight in for a public profile, a request for a private one; never someone who blocked you
create policy "follows ask" on public.follows for insert to authenticated with check (
  follower = auth.uid() and not public.blocked_either(followee) and (status = 'pending' or public.is_public(followee)));
create policy "follows accept" on public.follows for update to authenticated using (followee = auth.uid()) with check (followee = auth.uid());
create policy "follows remove" on public.follows for delete to authenticated using (follower = auth.uid() or followee = auth.uid());

-- posts: followers and (for public profiles) everyone can read them, and so react and comment
drop policy if exists "posts follow read" on public.posts;
create policy "posts follow read" on public.posts for select to authenticated using (
  not public.blocked_either(owner) and (public.is_follower(owner) or public.is_public(owner)));

create or replace function public.can_see_post(p uuid) returns boolean
language sql security definer stable as $$
  select exists (select 1 from public.posts x where x.id = p and (
    x.owner = auth.uid() or public.is_friend(x.owner)
    or (not public.blocked_either(x.owner) and (public.is_follower(x.owner) or public.is_public(x.owner)))));
$$;

-- counts for any profile (the rows themselves stay private)
create or replace function public.follow_counts(u uuid) returns table (followers bigint, following bigint)
language sql security definer stable as $$
  select (select count(*) from public.follows where followee = u and status = 'accepted'),
         (select count(*) from public.follows where follower = u and status = 'accepted');
$$;

-- people my friends follow, that I don't: "From your friends" on Find people
create or replace function public.follow_suggestions() returns table (user_id uuid, via uuid, n bigint)
language sql security definer stable as $$
  with mine as (
    select case when requester = auth.uid() then addressee else requester end as friend
    from public.friendships where status = 'accepted' and (requester = auth.uid() or addressee = auth.uid())
  )
  select f.followee, min(f.follower::text)::uuid, count(*)
  from public.follows f join mine on mine.friend = f.follower
  where f.status = 'accepted' and f.followee <> auth.uid()
    and not exists (select 1 from public.follows x where x.follower = auth.uid() and x.followee = f.followee)
    and not exists (select 1 from mine m2 where m2.friend = f.followee)
    and not public.blocked_either(f.followee)
  group by f.followee order by count(*) desc limit 20;
$$;

-- Explore: public profiles' posts from the last 3 weeks, most liked and commented first, newer ahead of older
create or replace function public.explore_posts(lim int default 60) returns setof public.posts
language sql security definer stable as $$
  select p.* from public.posts p
  join public.profiles pr on pr.user_id = p.owner and pr.private = false
  where p.created_at > now() - interval '21 days' and p.kind <> 'moment' and p.owner <> auth.uid()
    and not public.blocked_either(p.owner)
  order by (
    (select count(*) from public.reactions r where r.post_id = p.id) + 2 * (select count(*) from public.comments c where c.post_id = p.id) + 1
  ) / power(extract(epoch from (now() - p.created_at)) / 3600 + 2, 1.3) desc
  limit lim;
$$;

grant execute on function public.follow_counts(uuid), public.follow_suggestions(), public.explore_posts(int) to authenticated;
