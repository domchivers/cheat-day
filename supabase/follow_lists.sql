-- Who follows someone, and who they follow, for the lists that open from a profile's counts. A private profile's lists
-- are only for them, their friends and their followers; blocked people never show either way. Run once in the SQL
-- Editor, after followers_explore.sql. Safe to run again.

create or replace function public.follow_list(u uuid, which text) returns table (user_id uuid)
language sql security definer stable as $$
  select case when which = 'followers' then f.follower else f.followee end
  from public.follows f
  where f.status = 'accepted'
    and (case when which = 'followers' then f.followee else f.follower end) = u
    and (u = auth.uid() or public.is_public(u) or public.is_friend(u) or public.is_follower(u))
    and not public.blocked_either(u)
    and not public.blocked_either(case when which = 'followers' then f.follower else f.followee end)
  order by f.created_at desc
  limit 500;
$$;
grant execute on function public.follow_list(uuid, text) to authenticated;
