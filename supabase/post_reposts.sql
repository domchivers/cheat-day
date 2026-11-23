-- Reposts (23 Nov): a post shared on to your followers and kept in your profile's Reposts tab, credited to its
-- poster. Only someone else's post from a public account can be reposted (not a badge moment); a repost can be
-- seen by anyone who can see the post itself. Take one back by deleting it.
-- Safe to run more than once.

create table if not exists public.post_reposts (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
create index if not exists post_reposts_user on public.post_reposts (user_id, created_at desc);

alter table public.post_reposts enable row level security;

drop policy if exists "reposts read" on public.post_reposts;
create policy "reposts read" on public.post_reposts for select to authenticated
  using (public.can_see_post(post_id));

drop policy if exists "reposts add" on public.post_reposts;
create policy "reposts add" on public.post_reposts for insert to authenticated
  with check (
    user_id = auth.uid()
    and public.can_see_post(post_id)
    and exists (
      select 1 from public.posts p join public.profiles pr on pr.user_id = p.owner
      where p.id = post_id and p.owner <> auth.uid() and p.kind <> 'moment' and pr.private = false
    )
  );

drop policy if exists "reposts remove" on public.post_reposts;
create policy "reposts remove" on public.post_reposts for delete to authenticated
  using (user_id = auth.uid());

-- how many people have reposted each of these posts
create or replace function public.post_repost_counts(ids uuid[])
returns table(post_id uuid, n bigint)
language sql security definer set search_path = public stable as $$
  select r.post_id, count(*) from public.post_reposts r
  where r.post_id = any(ids) and public.can_see_post(r.post_id)
  group by r.post_id
$$;
revoke all on function public.post_repost_counts(uuid[]) from public;
grant execute on function public.post_repost_counts(uuid[]) to authenticated;
