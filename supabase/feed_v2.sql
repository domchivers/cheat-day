-- The feed: likes and replies on comments, and sending a post to one friend.
-- Run once in the Supabase SQL Editor (after the feed tables in README.md's "Share (the feed)").

alter table public.comments add column if not exists reply_to uuid references public.comments(id) on delete cascade;

create or replace function public.can_see_comment(c uuid) returns boolean
language sql security definer stable as $$
  select exists (select 1 from public.comments x where x.id = c and public.can_see_post(x.post_id));
$$;

create table if not exists public.comment_likes (
  comment_id uuid not null references public.comments(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (comment_id, user_id)
);
alter table public.comment_likes enable row level security;
create policy "comment likes read" on public.comment_likes for select to authenticated using (public.can_see_comment(comment_id));
create policy "comment likes own" on public.comment_likes for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid() and public.can_see_comment(comment_id));

create table if not exists public.post_shares (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  from_user uuid not null references auth.users(id) on delete cascade,
  to_user uuid not null references auth.users(id) on delete cascade,
  note text not null default '',
  created_at timestamptz not null default now()
);
alter table public.post_shares enable row level security;
create policy "post shares read" on public.post_shares for select to authenticated using (from_user = auth.uid() or to_user = auth.uid());
create policy "post shares create" on public.post_shares for insert to authenticated with check (from_user = auth.uid() and public.is_friend(to_user) and public.can_see_post(post_id));
create policy "post shares delete" on public.post_shares for delete to authenticated using (from_user = auth.uid() or to_user = auth.uid());
-- a post sent to you can be seen, even from a friend of a friend
create policy "posts shared read" on public.posts for select to authenticated using (exists (select 1 from public.post_shares s where s.post_id = posts.id and s.to_user = auth.uid()));
