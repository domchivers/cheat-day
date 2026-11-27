-- How the AI spending has been going, from the ai_usage table the "ai" function writes (US$, as Anthropic charges).
-- Supabase: SQL Editor -> New query -> paste -> Run. Read-only: it changes nothing.

-- 1. Each day, the last 30 days
select date_trunc('day', at)::date as day, count(*) as calls, round(sum(cost), 2) as usd,
       count(distinct user_id) as people
from public.ai_usage where at > now() - interval '30 days'
group by 1 order by 1 desc;

-- 2. By job and model, the last 30 days: where the money goes
select job, model, count(*) as calls, round(sum(cost), 2) as usd, round(avg(cost), 4) as usd_per_call,
       round(avg(ms) / 1000.0, 1) as seconds
from public.ai_usage where at > now() - interval '30 days'
group by 1, 2 order by usd desc;

-- 3. Per person, the last 30 days (the cost per user the pricing depends on)
select user_id, count(*) as calls, round(sum(cost), 2) as usd,
       count(distinct date_trunc('day', at)) as days_used,
       round(sum(cost) / greatest(count(distinct date_trunc('day', at)), 1), 3) as usd_per_day_used
from public.ai_usage where at > now() - interval '30 days'
group by 1 order by usd desc;

-- 4. All time
select count(*) as calls, round(sum(cost), 2) as usd, min(at) as since from public.ai_usage;
