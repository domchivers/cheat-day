-- Saved posts: a bookmark on a post, kept for yourself. Who saved what is private (only you can read your own
-- saves); how many people have saved a post is a number anyone signed in may ask for.
-- Safe to run more than once.

create table if not exists public.post_saves (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
create index if not exists post_saves_user on public.post_saves (user_id, created_at desc);

alter table public.post_saves enable row level security;
drop policy if exists "saves own" on public.post_saves;
create policy "saves own" on public.post_saves for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and public.can_see_post(post_id));

-- how many people have saved each of these posts: the number only, never who
create or replace function public.post_save_counts(ids uuid[])
returns table(post_id uuid, n bigint)
language sql security definer set search_path = public stable as $$
  select s.post_id, count(*) from public.post_saves s where s.post_id = any(ids) group by s.post_id
$$;
revoke all on function public.post_save_counts(uuid[]) from public;
grant execute on function public.post_save_counts(uuid[]) to authenticated;
