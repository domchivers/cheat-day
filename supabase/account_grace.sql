-- Account deletion with 30 days to change your mind (1.4.75).
-- Run once in the Supabase SQL Editor. Safe to run again.
--
-- Deleting in the app now marks the account (profiles.delete_after = 30 days on) instead of wiping it. While it's
-- marked, nobody else sees its profile, posts, stories, comments, likes, follows, friendships, days or stats: each table
-- gets a RESTRICTIVE select policy, which is ANDed with the policies already there, so nothing that exists changes.
-- Signing in again within the 30 days calls cancel_deletion() and it all comes back. After 30 days the nightly sweep
-- (delete-account with { sweep: true }, scheduled in Integrations -> Cron) erases it for good.

alter table public.profiles add column if not exists delete_after timestamptz;
create index if not exists profiles_delete_after on public.profiles (delete_after) where delete_after is not null;

-- someone else's account that's waiting to be deleted (your own is never "gone" to you)
create or replace function public.gone(u uuid) returns boolean
language sql security definer stable as $$
  select u is distinct from auth.uid() and exists (select 1 from public.profiles p where p.user_id = u and p.delete_after is not null);
$$;

-- the app's "Delete for good", after the password check in delete-account: called by the function with the
-- caller's own sign-in, so it only ever marks the caller. Null when there's no profile row to mark (it never
-- shared anything): the function then erases it straight away.
create or replace function public.request_deletion() returns timestamptz
language plpgsql security definer as $$
declare d timestamptz;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  update public.profiles set delete_after = coalesce(delete_after, now() + interval '30 days')
    where user_id = auth.uid() returning delete_after into d;
  return d;
end $$;

-- signing in again: true when it was waiting to be deleted and isn't any more
create or replace function public.cancel_deletion() returns boolean
language plpgsql security definer as $$
declare n int;
begin
  update public.profiles set delete_after = null where user_id = auth.uid() and delete_after is not null;
  get diagnostics n = row_count;
  return n > 0;
end $$;

revoke all on function public.request_deletion() from public, anon;
revoke all on function public.cancel_deletion() from public, anon;
grant execute on function public.request_deletion() to authenticated;
grant execute on function public.cancel_deletion() to authenticated;

-- the person can't clear delete_after by editing their own profile row: only cancel_deletion() (signing in) does
create or replace function public.keep_delete_after() returns trigger
language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') then new.delete_after := old.delete_after; end if;
  return new;
end $$;
drop trigger if exists keep_delete_after on public.profiles;
create trigger keep_delete_after before update on public.profiles for each row execute function public.keep_delete_after();

-- hide a marked account from everyone else; a table that doesn't exist here is skipped
do $$
declare t text; cols text[]; cond text; spec record;
begin
  for spec in select * from (values
    ('profiles', array['user_id']), ('posts', array['owner']), ('comments', array['user_id']),
    ('reactions', array['user_id']), ('stories', array['owner']), ('highlights', array['owner']),
    ('friendships', array['requester', 'addressee']), ('follows', array['follower', 'followee']),
    ('days', array['user_id']), ('stats', array['user_id']), ('shared_meals', array['owner']),
    ('comment_likes', array['user_id'])
  ) as s(tbl, c) loop
    t := spec.tbl; cols := spec.c;
    if to_regclass('public.' || t) is null then continue; end if;
    select string_agg(format('not public.gone(%I)', x), ' and ') into cond from unnest(cols) x;
    execute format('drop policy if exists "not gone" on public.%I', t);
    execute format('create policy "not gone" on public.%I as restrictive for select to authenticated using (%s)', t, cond);
  end loop;
end $$;
