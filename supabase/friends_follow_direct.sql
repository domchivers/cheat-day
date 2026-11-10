-- A friend can follow you straight away even when your profile is private (unfollowing a friend and following again
-- made a request). Everyone else still asks to follow a private profile. Run once in the SQL Editor, after
-- followers_explore.sql. Safe to run again.

drop policy if exists "follows ask" on public.follows;
create policy "follows ask" on public.follows for insert to authenticated with check (
  follower = auth.uid() and not public.blocked_either(followee)
  and (status = 'pending' or public.is_public(followee) or public.is_friend(followee)));
