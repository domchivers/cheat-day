-- Friends follow each other: when a friendship is accepted (scanning each other's code), both follow rows are made,
-- accepted, so a friend's profile says Following and the counts include each other. Friends already made are filled
-- in once below. Run once in the SQL Editor, after followers_explore.sql. Safe to run again.

create or replace function public.friends_follow() returns trigger
language plpgsql security definer as $$
begin
  if new.status = 'accepted' then
    insert into public.follows (follower, followee, status) values (new.requester, new.addressee, 'accepted'), (new.addressee, new.requester, 'accepted')
    on conflict (follower, followee) do update set status = 'accepted';
  end if;
  return new;
end $$;
drop trigger if exists friends_follow on public.friendships;
create trigger friends_follow after insert or update of status on public.friendships for each row execute function public.friends_follow();

-- the friends there already
insert into public.follows (follower, followee, status)
select requester, addressee, 'accepted' from public.friendships where status = 'accepted'
union
select addressee, requester, 'accepted' from public.friendships where status = 'accepted'
on conflict (follower, followee) do update set status = 'accepted';
