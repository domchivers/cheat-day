-- Polls on stories: one vote each, and everyone who can see the story sees the results once they've voted.
-- Run once in the SQL Editor, after stories.sql. Safe to run again.

create table if not exists public.story_poll_votes (
  story_id uuid not null references public.stories(id) on delete cascade,
  poll text not null,                 -- which poll on the story (its overlay id)
  voter uuid not null references auth.users(id) on delete cascade,
  choice int not null check (choice in (0, 1)),
  created_at timestamptz not null default now(),
  primary key (story_id, poll, voter)
);
alter table public.story_poll_votes enable row level security;
drop policy if exists "poll votes read" on public.story_poll_votes;
drop policy if exists "poll votes cast" on public.story_poll_votes;
drop policy if exists "poll votes change" on public.story_poll_votes;
create policy "poll votes read" on public.story_poll_votes for select to authenticated using (public.can_see_story(story_id));
create policy "poll votes cast" on public.story_poll_votes for insert to authenticated with check (voter = auth.uid() and public.can_see_story(story_id));
create policy "poll votes change" on public.story_poll_votes for update to authenticated using (voter = auth.uid()) with check (voter = auth.uid());
