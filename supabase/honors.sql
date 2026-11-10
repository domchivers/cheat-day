-- Profile labels and tags ("honors"). A label is chosen by each person ("Founder of Cheat Days", "Personal trainer").
-- Tags are given, never chosen: Founder (the owner), Team, Alpha (every account today), Beta (accounts made from now
-- until launch), First 100 and First 1,000 (by when the account was made). People choose only which of theirs sits
-- beside their name, and whether to show them. Run once in the SQL Editor. Safe to run again.

alter table public.profiles add column if not exists label text not null default '';
alter table public.profiles add column if not exists honors jsonb not null default '[]'::jsonb;
alter table public.profiles add column if not exists top_honor text not null default '';
alter table public.profiles add column if not exists show_honors boolean not null default true;

-- people can't give themselves tags: a change to honors from the app is put back (this editor and functions can)
create or replace function public.keep_honors() returns trigger
language plpgsql as $$
begin
  if coalesce(auth.role(), '') = 'authenticated' then new.honors := old.honors; end if;
  return new;
end $$;
drop trigger if exists keep_honors on public.profiles;
create trigger keep_honors before update on public.profiles for each row execute function public.keep_honors();

-- new accounts: Beta (until launch: drop this trigger then), and First 100 / First 1,000 by how many came before
create or replace function public.first_honors() returns trigger
language plpgsql security definer as $$
declare n bigint;
begin
  select count(*) into n from public.profiles;
  new.honors := coalesce(new.honors, '[]'::jsonb) || '["beta"]'::jsonb
    || case when n < 100 then '["first100"]'::jsonb when n < 1000 then '["first1000"]'::jsonb else '[]'::jsonb end;
  return new;
end $$;
drop trigger if exists first_honors on public.profiles;
create trigger first_honors before insert on public.profiles for each row execute function public.first_honors();

-- the accounts there today: Alpha, and First 100 / First 1,000 by sign-up order
with ordered as (
  select p.user_id, row_number() over (order by u.created_at) as n
  from public.profiles p join auth.users u on u.id = p.user_id
)
update public.profiles p set honors = (
  select jsonb_agg(distinct h) from jsonb_array_elements_text(
    p.honors || '["alpha"]'::jsonb || case when o.n <= 100 then '["first100"]'::jsonb when o.n <= 1000 then '["first1000"]'::jsonb else '[]'::jsonb end) h)
from ordered o where o.user_id = p.user_id;

-- the founder
update public.profiles set honors = (select jsonb_agg(distinct h) from jsonb_array_elements_text(honors || '["founder"]'::jsonb) h),
  top_honor = case when top_honor = '' then 'founder' else top_honor end
where user_id = (select id from auth.users where lower(email) = 'domchivers@gmail.com');

-- To give someone Team later:
-- update public.profiles set honors = honors || '["team"]'::jsonb where username = 'their.name';
