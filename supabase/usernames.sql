-- @names: one each (any capitals), and none that are offensive or pass as the app. Run once in the SQL Editor.
-- Unique @names were already enforced by profiles_messages.sql (a unique index on lower(username)); this keeps it.
create unique index if not exists profiles_username_key on public.profiles (lower(username)) where username is not null;

-- the same words as the app's Profiles.blocked, checked after undoing look-alikes (0 for o, 1 for i…)
create or replace function public.name_ok(n text) returns boolean
language sql immutable as $$
  select not exists (
    select 1 from unnest(array['fuck', 'fuk', 'shit', 'cunt', 'nigger', 'nigga', 'faggot', 'retard', 'whore', 'slut', 'rapist', 'nazi', 'hitler', 'kkk', 'bitch', 'pussy', 'porn', 'wank', 'twat', 'chink', 'kike', 'tranny', 'penis', 'vagina', 'boob', 'nude', 'naked', 'molest', 'paedo', 'pedophile', 'incel', 'jihad']) w
    where regexp_replace(translate(lower(coalesce(n, '')), '0134578@$!|', 'oieastbasii'), '[^a-z]', '', 'g') like '%' || w || '%');
$$;

create or replace function public.username_ok(u text) returns boolean
language sql immutable as $$
  select u is null or (public.name_ok(u) and not exists (
    select 1 from unnest(array['admin', 'administrator', 'cheatdays', 'cheatday', 'mycheatdays', 'support', 'official', 'help', 'staff', 'moderator', 'mod', 'system', 'root', 'owner', 'team', 'apple', 'anthropic']) r
    where regexp_replace(translate(lower(u), '0134578@$!|', 'oieastbasii'), '[^a-z]', '', 'g') = r));
$$;

do $$ begin
  alter table public.profiles add constraint profiles_username_clean check (public.username_ok(username)) not valid;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.profiles add constraint profiles_name_clean check (public.name_ok(display_name)) not valid;
exception when duplicate_object then null; end $$;
