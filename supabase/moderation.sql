-- Moderation: a report is looked at by the AI (the "moderate" function), hidden when it clearly breaks the rules, closed
-- when it's clearly fine, and sent to a person when the AI isn't sure. Whoever's content is removed is told and can
-- dispute it; a dispute always goes to a person. Anything reported as involving a child is hidden at once and goes
-- straight to a person, never to the AI.
-- Run once in the Supabase SQL Editor, after profiles_messages.sql, stories.sql and followers_explore.sql. Safe to run again.
-- Then make yourself a reviewer (your user id is in Authentication -> Users):
--   insert into public.moderators (user_id) values ('YOUR-USER-ID') on conflict do nothing;

-- ---- reports: what was reported, a copy of it (stories go after 24 hours), and what became of the report
alter table public.reports add column if not exists kind text not null default '';        -- post, story, comment, message, profile
alter table public.reports add column if not exists target text not null default '';      -- its id
alter table public.reports add column if not exists category text not null default '';    -- nudity, harassment, child, violence, spam, impersonation, other
alter table public.reports add column if not exists snapshot jsonb not null default '{}'::jsonb;   -- { text, media, video }
alter table public.reports add column if not exists status text not null default 'open'; -- open, cleared, removed, human, kept
alter table public.reports add column if not exists verdict jsonb;                        -- what the AI said: { verdict, rule, why, seen }
alter table public.reports add column if not exists decided_at timestamptz;
create index if not exists reports_status on public.reports (status, created_at);

-- ---- who reviews: nobody can read this table from the app; functions ask is_moderator()
create table if not exists public.moderators (user_id uuid primary key references auth.users(id) on delete cascade);
alter table public.moderators enable row level security;

create or replace function public.is_moderator() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.moderators where user_id = auth.uid());
$$;

-- ---- hidden content: only its owner and reviewers still see it
alter table public.posts add column if not exists hidden_at timestamptz;
alter table public.stories add column if not exists hidden_at timestamptz;
alter table public.comments add column if not exists hidden_at timestamptz;
alter table public.profiles add column if not exists suspended_until timestamptz;

-- restrictive: these narrow whatever the tables' own policies allow, without replacing them
drop policy if exists "posts not hidden" on public.posts;
create policy "posts not hidden" on public.posts as restrictive for select to authenticated
  using (hidden_at is null or owner = auth.uid() or public.is_moderator());
drop policy if exists "stories not hidden" on public.stories;
create policy "stories not hidden" on public.stories as restrictive for select to authenticated
  using (hidden_at is null or owner = auth.uid() or public.is_moderator());
drop policy if exists "comments not hidden" on public.comments;
create policy "comments not hidden" on public.comments as restrictive for select to authenticated
  using (hidden_at is null or user_id = auth.uid() or public.is_moderator());

-- nobody un-hides their own content or lifts their own suspension: only the functions below (and the service role) change these
create or replace function public.keep_hidden() returns trigger
language plpgsql as $$
begin
  if coalesce(auth.role(), '') = 'authenticated' and coalesce(current_setting('app.moderating', true), '') <> '1' then
    new.hidden_at := old.hidden_at;
  end if;
  return new;
end $$;
drop trigger if exists keep_hidden on public.posts;
create trigger keep_hidden before update on public.posts for each row execute function public.keep_hidden();
drop trigger if exists keep_hidden on public.stories;
create trigger keep_hidden before update on public.stories for each row execute function public.keep_hidden();
drop trigger if exists keep_hidden on public.comments;
create trigger keep_hidden before update on public.comments for each row execute function public.keep_hidden();

create or replace function public.keep_suspended() returns trigger
language plpgsql as $$
begin
  if coalesce(auth.role(), '') = 'authenticated' and coalesce(current_setting('app.moderating', true), '') <> '1' then
    new.suspended_until := old.suspended_until;
  end if;
  return new;
end $$;
drop trigger if exists keep_suspended on public.profiles;
create trigger keep_suspended before update on public.profiles for each row execute function public.keep_suspended();

-- a suspended account can read, but not post, comment, message or put up a story
create or replace function public.suspended() returns boolean
language sql security definer stable set search_path = public as $$
  select coalesce((select suspended_until > now() from public.profiles where user_id = auth.uid()), false);
$$;
drop policy if exists "posts not suspended" on public.posts;
create policy "posts not suspended" on public.posts as restrictive for insert to authenticated with check (not public.suspended());
drop policy if exists "stories not suspended" on public.stories;
create policy "stories not suspended" on public.stories as restrictive for insert to authenticated with check (not public.suspended());
drop policy if exists "comments not suspended" on public.comments;
create policy "comments not suspended" on public.comments as restrictive for insert to authenticated with check (not public.suspended());
drop policy if exists "messages not suspended" on public.messages;
create policy "messages not suspended" on public.messages as restrictive for insert to authenticated with check (not public.suspended());

-- Explore reads posts as the database owner, past the policies above: it leaves hidden ones out itself
create or replace function public.explore_posts(lim int default 60) returns setof public.posts
language sql security definer stable as $$
  select p.* from public.posts p
  join public.profiles pr on pr.user_id = p.owner and pr.private = false
  where p.created_at > now() - interval '21 days' and p.kind <> 'moment' and p.owner <> auth.uid()
    and p.hidden_at is null
    and not public.blocked_either(p.owner)
  order by (
    (select count(*) from public.reactions r where r.post_id = p.id) + 2 * (select count(*) from public.comments c where c.post_id = p.id) + 1
  ) / power(extract(epoch from (now() - p.created_at)) / 3600 + 2, 1.3) desc
  limit lim;
$$;

-- ---- what's been removed, for its owner to be told and to dispute
create table if not exists public.removals (
  id uuid primary key default gen_random_uuid(),
  kind text not null,
  target text not null,
  owner uuid not null references auth.users(id) on delete cascade,
  category text not null default '',
  why text not null default '',
  report_id uuid references public.reports(id) on delete set null,
  decided_by text not null default 'ai',      -- ai or human
  created_at timestamptz not null default now(),
  lifted_at timestamptz,                      -- put back
  unique (kind, target)
);
alter table public.removals enable row level security;
drop policy if exists "removals read" on public.removals;
create policy "removals read" on public.removals for select to authenticated using (owner = auth.uid() or public.is_moderator());

create table if not exists public.appeals (
  id uuid primary key default gen_random_uuid(),
  removal_id uuid not null unique references public.removals(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  text text not null default '',
  status text not null default 'open',        -- open, restored, upheld
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
alter table public.appeals enable row level security;
drop policy if exists "appeals read" on public.appeals;
create policy "appeals read" on public.appeals for select to authenticated using (user_id = auth.uid() or public.is_moderator());
drop policy if exists "appeals send" on public.appeals;
create policy "appeals send" on public.appeals for insert to authenticated with check (
  user_id = auth.uid() and exists (select 1 from public.removals r where r.id = removal_id and r.owner = auth.uid() and r.lifted_at is null));

-- ---- hiding and putting back: used by the moderate function (service role) and the reviewer functions below
create or replace function public.mod_hide(k text, t text, cat text, reason text, rep uuid, who text) returns void
language plpgsql security definer set search_path = public as $$
declare o uuid;
begin
  perform set_config('app.moderating', '1', true);
  if k = 'post' then update posts set hidden_at = now() where id::text = t returning owner into o;
  elsif k = 'story' then update stories set hidden_at = now() where id::text = t returning owner into o;
  elsif k = 'comment' then update comments set hidden_at = now() where id::text = t returning user_id into o;
  end if;
  if o is not null then
    insert into removals (kind, target, owner, category, why, report_id, decided_by) values (k, t, o, cat, reason, rep, who)
    on conflict (kind, target) do update set lifted_at = null, category = excluded.category, why = excluded.why,
      report_id = excluded.report_id, decided_by = excluded.decided_by, created_at = now();
  end if;
end $$;

create or replace function public.mod_show(k text, t text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('app.moderating', '1', true);
  if k = 'post' then update posts set hidden_at = null where id::text = t;
  elsif k = 'story' then update stories set hidden_at = null where id::text = t;
  elsif k = 'comment' then update comments set hidden_at = null where id::text = t;
  end if;
  update removals set lifted_at = now() where kind = k and target = t and lifted_at is null;
end $$;

revoke execute on function public.mod_hide(text, text, text, text, uuid, text) from public, anon, authenticated;
revoke execute on function public.mod_show(text, text) from public, anon, authenticated;
grant execute on function public.mod_hide(text, text, text, text, uuid, text) to service_role;
grant execute on function public.mod_show(text, text) to service_role;

-- ---- the reviewer's side
-- what's waiting: reports the AI passed on (or that never went to it), and disputes
create or replace function public.mod_queue() returns jsonb
language sql security definer stable set search_path = public as $$
  select case when not public.is_moderator() then jsonb_build_object('reports', '[]'::jsonb, 'appeals', '[]'::jsonb) else jsonb_build_object(
    'reports', coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at) from reports r where r.status = 'human'), '[]'::jsonb),
    'appeals', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'text', a.text, 'created_at', a.created_at, 'user_id', a.user_id,
                                                              'removal', to_jsonb(m), 'report', to_jsonb(r)) order by a.created_at)
                         from appeals a join removals m on m.id = a.removal_id left join reports r on r.id = m.report_id
                         where a.status = 'open'), '[]'::jsonb)) end;
$$;

-- keep it up, remove it, or remove it and suspend whoever posted it for some days
create or replace function public.mod_decide(rep uuid, act text, days int default 0) returns void
language plpgsql security definer set search_path = public as $$
declare r reports;
begin
  if not public.is_moderator() then raise exception 'Not a reviewer'; end if;
  select * into r from reports where id = rep;
  if r.id is null then return; end if;
  if act = 'keep' then
    perform mod_show(r.kind, r.target);
  else
    perform mod_hide(r.kind, r.target, r.category, 'Removed after a review', r.id, 'human');
    if act = 'suspend' then
      perform set_config('app.moderating', '1', true);
      update profiles set suspended_until = now() + make_interval(days => greatest(1, days)) where user_id = r.reported;
    end if;
  end if;
  -- every report of the same thing is settled with it
  update reports set status = case when act = 'keep' then 'kept' else 'removed' end, decided_at = now()
   where id = rep or (kind = r.kind and target = r.target and target <> '' and status in ('open', 'human'));
end $$;

-- a dispute: put it back, or leave it removed
create or replace function public.mod_appeal(ap uuid, act text) returns void
language plpgsql security definer set search_path = public as $$
declare m removals;
begin
  if not public.is_moderator() then raise exception 'Not a reviewer'; end if;
  select x.* into m from removals x join appeals a on a.removal_id = x.id where a.id = ap;
  if m.id is null then return; end if;
  if act = 'restore' then perform mod_show(m.kind, m.target); end if;
  update appeals set status = case when act = 'restore' then 'restored' else 'upheld' end, decided_at = now() where id = ap;
end $$;

grant execute on function public.is_moderator(), public.suspended(), public.mod_queue(), public.mod_decide(uuid, text, int), public.mod_appeal(uuid, text) to authenticated;
