-- The app's own @names (cheatdays, mycheatdays, support…) for the team's accounts (28 Nov). usernames.sql refused them
-- for everyone, Founder included, and a check is run on every save of a row: an account already holding one couldn't
-- save anything. Founder or Team accounts may now hold them; everyone else still can't. Run once in the SQL Editor.
-- Safe to run again.

alter table public.profiles drop constraint if exists profiles_username_clean;
alter table public.profiles add constraint profiles_username_clean
  check (public.username_ok(username) or honors ?| array['founder', 'team']) not valid;

-- the app's own account (the brand page, @mycheatdays or @mycheatdays.app today): Team
update public.profiles set honors = honors || '["team"]'::jsonb
where lower(username) like 'mycheatdays%' and not honors ? 'team';

-- check: the account and its tags (one row with "team" in honors; nobody else already has @cheatdays)
select username, display_name, honors from public.profiles where lower(username) like 'mycheatdays%' or lower(username) = 'cheatdays';
