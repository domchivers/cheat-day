-- Group chats (25 Nov, design/group-chats-mockup.html): a named group of people, its messages in the same messages
-- table as one-to-one chats (group_id set, to_user empty), and an invite code anyone with it can join by.
-- Who can be added: your friends, or people you follow who follow you back. Whoever made a group can remove people;
-- anyone can leave. Run once in the Supabase SQL Editor. Safe to run again.

create table if not exists public.chat_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  created_by uuid not null default auth.uid() references auth.users(id) on delete cascade,
  invite text not null unique default substr(md5(random()::text || clock_timestamp()::text), 1, 10),
  created_at timestamptz not null default now()
);

create table if not exists public.chat_group_members (
  group_id uuid not null references public.chat_groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  added_by uuid references auth.users(id) on delete set null,
  seen_at timestamptz,
  muted boolean not null default false,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index if not exists chat_group_members_user on public.chat_group_members (user_id);

-- a message goes to one person or one group
alter table public.messages alter column to_user drop not null;
alter table public.messages add column if not exists group_id uuid references public.chat_groups(id) on delete cascade;
do $$ begin
  alter table public.messages add constraint messages_one_target check ((to_user is null) <> (group_id is null));
exception when duplicate_object then null; end $$;
create index if not exists messages_group on public.messages (group_id, created_at desc) where group_id is not null;

-- whether I'm in a group (security definer: the members table's own rules ask this)
create or replace function public.in_group(g uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.chat_group_members where group_id = g and user_id = auth.uid());
$$;

-- whether I can put someone in a group: a friend, or we follow each other
create or replace function public.can_add_to_group(u uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select public.is_friend(u) or (
    exists (select 1 from public.follows where follower = auth.uid() and followee = u and status = 'accepted') and
    exists (select 1 from public.follows where follower = u and followee = auth.uid() and status = 'accepted'));
$$;

alter table public.chat_groups enable row level security;
drop policy if exists "groups read" on public.chat_groups;
drop policy if exists "groups make" on public.chat_groups;
drop policy if exists "groups rename" on public.chat_groups;
drop policy if exists "groups delete" on public.chat_groups;
create policy "groups read" on public.chat_groups for select to authenticated using (created_by = auth.uid() or public.in_group(id));
create policy "groups make" on public.chat_groups for insert to authenticated with check (created_by = auth.uid());
create policy "groups rename" on public.chat_groups for update to authenticated using (public.in_group(id)) with check (public.in_group(id));
create policy "groups delete" on public.chat_groups for delete to authenticated using (created_by = auth.uid());

alter table public.chat_group_members enable row level security;
drop policy if exists "group members read" on public.chat_group_members;
drop policy if exists "group members add" on public.chat_group_members;
drop policy if exists "group members own" on public.chat_group_members;
drop policy if exists "group members remove" on public.chat_group_members;
create policy "group members read" on public.chat_group_members for select to authenticated using (public.in_group(group_id));
-- yourself into a group you just made, or someone you can add into a group you're in
create policy "group members add" on public.chat_group_members for insert to authenticated with check (
  (user_id = auth.uid() and exists (select 1 from public.chat_groups g where g.id = group_id and g.created_by = auth.uid()))
  or (public.in_group(group_id) and public.can_add_to_group(user_id)));
-- your own row: when you last read it, muted
create policy "group members own" on public.chat_group_members for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
-- leave, or (whoever made it) remove someone
create policy "group members remove" on public.chat_group_members for delete to authenticated using (
  user_id = auth.uid() or exists (select 1 from public.chat_groups g where g.id = group_id and g.created_by = auth.uid()));

-- messages: one-to-one as before, and a group's for its members
drop policy if exists "messages read" on public.messages;
drop policy if exists "messages send" on public.messages;
create policy "messages read" on public.messages for select to authenticated
  using (from_user = auth.uid() or to_user = auth.uid() or (group_id is not null and public.in_group(group_id)));
create policy "messages send" on public.messages for insert to authenticated with check (from_user = auth.uid() and (
  (group_id is null and to_user is not null and public.is_friend(to_user)) or
  (group_id is not null and to_user is null and public.in_group(group_id))));

-- reactions on a group's messages, for its members
create or replace function public.in_my_chat(m uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.messages x where x.id = m and
    (x.from_user = auth.uid() or x.to_user = auth.uid() or (x.group_id is not null and public.in_group(x.group_id))));
$$;

-- joining by an invite code ("cheatdays://group/ab12cd34ef"): the group's id, or null for a code that isn't one
create or replace function public.join_group(code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare g uuid;
begin
  if auth.uid() is null then return null; end if;
  select id into g from public.chat_groups where invite = lower(trim(code));
  if g is null then return null; end if;
  insert into public.chat_group_members (group_id, user_id) values (g, auth.uid()) on conflict do nothing;
  return g;
end $$;
grant execute on function public.join_group(text) to authenticated;
