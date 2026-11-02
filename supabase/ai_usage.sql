-- What each Claude call cost, per person: the daily limit and the two-week trial read this.
-- Run once in Supabase: SQL Editor -> New query -> paste -> Run.
-- Row level security with no policies: only the server function can read or write it.
create table if not exists public.ai_usage (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  user_id uuid not null references auth.users (id) on delete cascade,
  job text not null,
  model text not null,
  input_tokens integer not null,
  output_tokens integer not null,
  cost numeric(10, 6) not null,
  ms integer,
  stop text
);
create index if not exists ai_usage_user_at on public.ai_usage (user_id, at desc);
alter table public.ai_usage enable row level security;
