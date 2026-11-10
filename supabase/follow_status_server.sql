-- The server decides whether a follow goes straight in or is a request: straight in for a public profile or a friend,
-- a request otherwise, whatever the app asked for (tapping Follow fast could send a request to a friend). Also turns any
-- request already sitting between friends into a follow. Run once in the SQL Editor, after friends_follow_direct.sql.
-- Safe to run again.

create or replace function public.follow_status() returns trigger
language plpgsql security definer as $$
begin
  if public.is_public(new.followee) or exists (
    select 1 from public.friendships f where f.status = 'accepted'
      and ((f.requester = new.follower and f.addressee = new.followee) or (f.addressee = new.follower and f.requester = new.followee))
  ) then
    new.status := 'accepted';
  else
    new.status := 'pending';
  end if;
  return new;
end $$;
drop trigger if exists follow_status on public.follows;
create trigger follow_status before insert on public.follows for each row execute function public.follow_status();

-- requests already sitting between friends
update public.follows fo set status = 'accepted'
where fo.status = 'pending' and exists (
  select 1 from public.friendships f where f.status = 'accepted'
    and ((f.requester = fo.follower and f.addressee = fo.followee) or (f.addressee = fo.follower and f.requester = fo.followee)));
