-- What the giphy function has fetched, shared by everyone so the free key's 100 calls an hour go a long way:
-- trending kept for an hour, each search for a day. Only the function reads and writes it (no policies: the app can't).
-- Run once in the SQL Editor.

create table if not exists public.giphy_cache (
  key text primary key,
  data jsonb not null default '[]'::jsonb,
  fetched_at timestamptz not null default now()
);
alter table public.giphy_cache enable row level security;
