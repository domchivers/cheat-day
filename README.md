# Cheat Days

Spend your cheat-day calories on purpose. Set a budget (say 1,600 kcal), scan
what you're about to eat, say how big a slice of the day it should be ("10%",
"1/6", "250 kcal") and it tells you how many grams, servings or pieces that is.
Add it to the day and watch the ring fill up.

No accounts, no server, no build step. Everything stays on the device.

## How to open

**Double-click `start.bat`** — it starts a tiny local server and opens the app.
Keep the black window open while you use it.

### On your phone (same Wi-Fi)

1. On the PC, run `start.bat`. It prints the address to use, e.g.
   `http://192.168.1.103:8010/index.html`. The first time, Windows may ask to
   let Python through the firewall — allow it.
2. Open that address in Safari / Chrome on the phone.
3. **Share → Add to Home Screen** for an app icon.

## Three ways to add an item

| Source | What happens |
| --- | --- |
| **Scan** | One camera for both. A barcode (held any way up) is looked up on [Open Food Facts](https://world.openfoodfacts.org), free, no key needed. If no barcode turns up for a few seconds and the API key is set, the app sends a frame to Claude to see whether it's looking at a nutrition table, and creates the product from it if so (at most twice per scan). "Read the label" does the same on demand. Things eaten by the piece, like sliced bread, biscuits, bars or sausages, come through with a piece name and weight so you can just say how many. |
| **Type it in** | You enter kcal per 100 g (or per serving) and whatever else you know. |

Whatever the source, you land on an editable "check the details" form before
choosing your share, so a wrong reading is a quick fix rather than a wrong day.

## Accounts and sync

Out of the box everything lives in the browser on one device. Signing in (Settings →
Account) adds a cloud copy so days, past days and the Quick add list follow you to
every device. It uses the **same Supabase project as the Chinese app**, so the same
email and password work in both; `supabase-config.js` holds the project URL and the
public anon key (safe in a public repo; row-level security protects the data).

One-off setup, once: in the Supabase dashboard open **SQL Editor**, paste this and Run.

```sql
create table if not exists public.cheatday (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.cheatday enable row level security;
create policy "own cheatday" on public.cheatday
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
```

Sync is local-first and last-write-wins: the newest copy replaces the older one
whole, so removing an item on one phone stays removed. The Anthropic API key
deliberately stays on each device.

## Search

The **Search** card finds food three ways, in this order:

1. **Everyday foods** from `foods.js`, a bundled list of a few hundred common
   things (chicken thigh, eggs, rice, a glass of wine, a doner kebab…) with
   typical kcal per 100 g and a sensible serving. Meat, fish and grains come cooked
   and raw, so you can weigh before or after cooking. Instant and offline. Add your
   own rows at the bottom of that file.
2. **Open Food Facts** text search for branded products, a moment later. Their
   search service is often busy, so this one is best-effort.
3. **Ask Claude** (needs the API key) for anything else. It's an estimate from
   standard reference values, and the details page says so.

## Meals

The **Meals** card is for a cake, a curry, anything made from several
ingredients that you want to add as one thing. In the editor:

- **Search** or **Scan** an ingredient, say how much went in, and it's added.
- **Paste a list** takes one ingredient per line ("200g plain flour", "3 eggs",
  "1 tbsp honey", "zest of a lemon") and matches each to the food list. Lines it
  can't place are highlighted: tap one and pick what it is. Tap any matched
  line to change the amount, swap it for a scanned brand, or remove it.
- Set how many portions it makes, then **Save meal**.

A saved meal behaves like any food: add one portion or three to a day, find it
in Search, and it appears in Quick add. Editing a meal later doesn't change days
it was already added to.

## Friends

The **Friends** card needs an account (Settings → Account). Everyone gets a
friend code like `DOM-4821`; add a friend by typing theirs, they accept, done.
Friends then see each other's day (today's total and what was eaten, switchable
off), a **This week** table sorted by days on budget, and a **From friends**
list of meals shared with "Share with friends" in the meal editor.

One-off setup in the Supabase SQL Editor, in addition to the `cheatday` table:

```sql
create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  friend_code text unique not null,
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
create policy "profiles read" on public.profiles for select to authenticated using (true);
create policy "profiles insert" on public.profiles for insert to authenticated with check (auth.uid() = user_id);
create policy "profiles update" on public.profiles for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

create table if not exists public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester uuid not null references auth.users(id) on delete cascade,
  addressee uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  unique (requester, addressee)
);
alter table public.friendships enable row level security;
create policy "friendships see" on public.friendships for select to authenticated using (auth.uid() = requester or auth.uid() = addressee);
create policy "friendships request" on public.friendships for insert to authenticated with check (auth.uid() = requester and requester <> addressee);
create policy "friendships accept" on public.friendships for update to authenticated using (auth.uid() = addressee) with check (auth.uid() = addressee);
create policy "friendships remove" on public.friendships for delete to authenticated using (auth.uid() = requester or auth.uid() = addressee);

create or replace function public.is_friend(other uuid) returns boolean
language sql security definer stable as $$
  select exists (
    select 1 from public.friendships f where f.status = 'accepted'
      and ((f.requester = auth.uid() and f.addressee = other) or (f.addressee = auth.uid() and f.requester = other))
  );
$$;

create table if not exists public.shared_meals (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references auth.users(id) on delete cascade,
  meal_id text not null,
  name text not null,
  portions numeric not null default 1,
  kcal_per_portion numeric not null default 0,
  items jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  unique (owner, meal_id)
);
alter table public.shared_meals enable row level security;
create policy "shared meals read" on public.shared_meals for select to authenticated using (owner = auth.uid() or public.is_friend(owner));
create policy "shared meals own" on public.shared_meals for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());

create table if not exists public.days (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  budget integer not null default 0,
  kcal integer not null default 0,
  items jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (user_id, day)
);
alter table public.days enable row level security;
create policy "days read" on public.days for select to authenticated using (user_id = auth.uid() or public.is_friend(user_id));
create policy "days own" on public.days for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
```

## AI for free: Gemini, and one shared key

The AI features (label photos, guessing a plate, planning the rest of the day,
making meals and products lighter) can run on Google Gemini's free tier instead
of a paid Anthropic key. Two ways to set it up:

1. **On each phone**: get a free key at [aistudio.google.com](https://aistudio.google.com)
   (Google account, no card) and paste it into Settings → Google Gemini key.
2. **Once, for everyone (recommended)**: keep the key on the app's own server so
   friends never paste anything. In the Supabase dashboard: **Edge Functions →
   Deploy a new function → via editor**, name it `ai`, paste the contents of
   `supabase/functions/ai/index.ts`, Deploy. Then **Edge Functions → Secrets →
   Add**: name `GEMINI_API_KEY`, value your Gemini key. Signed-in users then use
   it automatically; the app falls back to a key on the phone if the function
   isn't there.

An Anthropic key still works and is used only when there's no Gemini route.

## Photos on what you log

The How much? screen has "Add a photo" (camera or library); anything you
photographed for a label read or an estimate is attached automatically. Meals
take a photo in their editor. Photos show as the thumbnails in Today, History
and the Meals list, travel in shared links, and are kept small (about 10 KB)
so they don't weigh down the app or sync. History keeps them for two weeks.

## Workouts

The **Workouts** card logs activities (walk, run, cycle, swim, gym weights,
HIIT and more) with minutes and an effort level, and estimates the calories
burned from standard intensity figures and your weight (set on the Daily
budget screen; 75 kg assumed otherwise). Gym sessions can carry a lifting log:
exercise, sets × reps at kg, remembered from last time, total volume, and a
"New best" note when you beat your estimated one-rep max. The tab leads with a
week strip (a bar per day, ticks on training days, a streak count) and, if
eat-back is on, what your budget is now. **Start gym session** runs a live
session: add exercises (pre-filled from last time), tick sets as you finish
them, a 90 s rest timer starts on its own, and Finish logs it with the real
duration and offers to save it as a **routine**. Routines start with one tap
(hold to remove). **Personal bests** lists each exercise's best set; tap one for
its stats and a chart of estimated 1RM over the last sessions. Two chips send
the assistant your lifting history: suggest a workout, how am I progressing.
"New best" note when you beat your estimated one-rep max. Recent workouts come
back as one-tap quick adds, and "ran 5k in 28 min" in the Just tell it box or
the Assistant logs one too. Burned calories are recorded and shown on the home
card; Settings has a switch to add them to the day's budget, off by default.

## About my eating

On the Daily budget screen there's a free-text box the assistant reads on every
request: habits ("every meal I have 220 g cooked rice"), rules ("no dairy"),
usual portions. It shapes plans, recipes and lighter versions. Every photo
button also offers "from my photos" as well as the camera.

## Just tell it

Under Today on the home screen there's a box you can talk to: "add a banana",
"I only had two eggs", "remove the toast", "set my budget to 2,000". It shows
the changes it understood and applies them when you tap Apply. The How much?
screen has the same for one item ("added extra beef rolls, didn't drink the
soup"), and the lighter and plan results take follow-ups too ("no egg, cut it
further"). All of these use the AI key.

## Macro goals, the Assistant, and the rest of the day

The Daily budget screen also takes protein, carbs and fat goals in grams (or
"Suggest from my calories" for a 30/40/30 split); the home tiles then show
progress against them. The **Assistant** card is one conversation for
everything AI: photograph a plate and say what it is for an estimate, ask for a
plan for the rest of the day, ask for a recipe ("high-protein chicken curry for
4 under 500 kcal a portion", saved straight into Meals with its method), ask for
a lighter way to have something, or tell it what you actually ate and it fixes
today's list. Each answer is a card with a button to act on it, and you can
keep talking to refine it. "What fits what's left" needs no key: it picks foods
from the built-in list that fit the remaining calories, favouring what you're
short on. Product pages and meal editors also have **Make it lighter** and a box
to ask anything about that item ("more protein", "swap the rice", "add cheese").

## Days and History

The day turns over by itself at midnight: what you logged goes into **History**
(the link beside Today, or Settings → See history) with its items and macros,
and Today starts empty. "Start a new day now" in Settings does the same early.

## Body (scale readings)

The Workouts tab has a **Body** card: weight, body fat, muscle mass, water,
bone, visceral fat and metabolic age, typed in or posted by a Shortcut, with a
chart per metric and 30-day change. The latest weight feeds the workout burn
estimate. Readings live in your synced data and, when signed in, in a
`body_metrics` table so a Shortcut can add to them.

**Connect a scale (iPhone).** Scales like Etekcity write to Apple Health. The
Body screen gives you a private link (your token is in it); a two-action iPhone
Shortcut (Find Health Samples, then Get Contents of URL as POST with the samples
as the body) runs every morning. The function accepts JSON or text like "78.4 kg". One-off setup:

```sql
create table if not exists public.body_metrics (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  weight numeric, fat numeric, lean numeric, muscle numeric, water numeric, bone numeric, visceral numeric, bmr numeric, age numeric, bmi numeric,
  updated_at timestamptz not null default now(),
  primary key (user_id, day)
);
alter table public.body_metrics enable row level security;
create policy "body own" on public.body_metrics for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create table if not exists public.import_tokens (
  user_id uuid primary key references auth.users(id) on delete cascade,
  token text unique not null,
  created_at timestamptz not null default now()
);
alter table public.import_tokens enable row level security;
create policy "tokens own" on public.import_tokens for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
```

Then deploy `supabase/functions/body-import/index.ts` as an Edge Function named
`body-import` with **Verify JWT turned off** (the token is the secret). The
Shortcut steps are on the Body screen under "How to set up the Shortcut".

## Goals and rewards

A small game on top of the tracking. The home page shows your **level** and an
XP bar; tap it for the Goals screen. **Weekly goals** (Monday to Sunday) are
days under budget, days hitting protein, workouts, and days logged, each with a
target you can change by tapping the goal (0 switches it off). **XP** comes from logging a day, finishing
a day under budget, hitting protein, workouts, lifting PBs, posts, and finished
weekly goals; it is worked out from your history, so nothing double counts.
**Badges** unlock for firsts, streaks, workout and PB counts, and posts, with a
toast when one lands.

## Send to a friend

Ate the same thing as someone? On the How much? screen, **Send to a friend**
lists your friends; tap one and the item (name, amount, calories, photo) lands
on their home page as a card with a ＋. They tap it, check the amount, and it's
on their day. One-off setup in the Supabase SQL Editor:

```sql
create table if not exists public.sends (
  id uuid primary key default gen_random_uuid(),
  from_user uuid not null references auth.users(id) on delete cascade,
  to_user uuid not null references auth.users(id) on delete cascade,
  name text not null,
  kcal integer not null default 0,
  grams numeric,
  unit text,
  photo text,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'new',
  created_at timestamptz not null default now()
);
alter table public.sends enable row level security;
create policy "sends read" on public.sends for select to authenticated using (from_user = auth.uid() or to_user = auth.uid());
create policy "sends create" on public.sends for insert to authenticated with check (from_user = auth.uid() and public.is_friend(to_user));
create policy "sends settle" on public.sends for update to authenticated using (to_user = auth.uid()) with check (to_user = auth.uid());
create policy "sends delete" on public.sends for delete to authenticated using (from_user = auth.uid());
```

## Share (the feed)

The **Share** card is a feed between friends: post what you're having from the
How much? screen ("Add and share it") or a meal ("Post to the feed"), with a
photo and a caption. Friends react (👍 ❤️ 🔥 😋), comment, and repost: for a
food that means "Add to my day", for a meal "Save meal", optionally sharing it
on with their own caption. One-off setup in the Supabase SQL Editor:

```sql
create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references auth.users(id) on delete cascade,
  kind text not null default 'food',
  name text not null,
  caption text not null default '',
  photo text,
  kcal integer not null default 0,
  macros jsonb not null default '{}'::jsonb,
  payload jsonb not null default '{}'::jsonb,
  extra jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.posts enable row level security;
create policy "posts read" on public.posts for select to authenticated using (owner = auth.uid() or public.is_friend(owner));
create policy "posts own" on public.posts for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());

create or replace function public.can_see_post(p uuid) returns boolean
language sql security definer stable as $$
  select exists (select 1 from public.posts x where x.id = p and (x.owner = auth.uid() or public.is_friend(x.owner)));
$$;

create table if not exists public.reactions (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  emoji text not null,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id, emoji)
);
alter table public.reactions enable row level security;
create policy "reactions read" on public.reactions for select to authenticated using (public.can_see_post(post_id));
create policy "reactions own" on public.reactions for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid() and public.can_see_post(post_id));

create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  text text not null,
  created_at timestamptz not null default now()
);
alter table public.comments enable row level security;
create policy "comments read" on public.comments for select to authenticated using (public.can_see_post(post_id));
create policy "comments own" on public.comments for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid() and public.can_see_post(post_id));
```

## Macros

Everything carries protein, carbs and fat where they're known: the built-in food
list has them, barcodes bring them from Open Food Facts, label photos read them,
and the details page lets you type them. The budget card on the home screen
totals them for the day, each item shows its share, and meals show per portion.

## Sharing a meal

A saved meal has **Share this meal**. The whole recipe is packed into the link
itself, so there's nothing to host: whoever opens it in Cheat Days is asked
whether to add it to their meals. The daily budget is now edited by tapping the
budget card; the gear is for account, API key and updates.

## Quick add


**Quick add** on the home screen is a row you tap open. It holds things you have
often, most-used first, added to the day in one tap: your saved meals, anything
you've added before, and the presets below. They live in `presets.js`: one entry per item with a name, a
short description, the kcal for one of it, and a word for the unit ("drink",
"slice"). Add more entries to that list and push.

## Shares you can type

`10%` · `1/6` · `0.15` · `15` (means 15%) · `250 kcal` · or tap **What's left**
to spend the remainder of the day.

## Camera note

Browsers only allow the *live* camera feed over HTTPS or `localhost`. Over a
plain `http://192.168…` address on your phone, the app falls back to the
phone's camera app via "take a photo" — the barcode is decoded from that photo.
Both routes are automatic; you'll just see one button or the other.

## Files

- `index.html`, `styles.css`, `app.js` — the whole app
- `presets.js` — the Quick add list
- `foods.js` — everyday foods for Search
- `cloud.js`, `supabase-config.js` — accounts + sync (Supabase, shared with the Chinese app)
- `vendor/zxing.min.js` — barcode decoding ([@zxing/library](https://github.com/zxing-js/library) 0.21.3, UMD build)
- `sw.js`, `manifest.webmanifest`, `icons/` — install-to-home-screen and offline cache
- `make_icons.py` — regenerates the icons (needs Pillow)
- `start.bat` — local server on port 8010

When you change app files, bump `APP_VERSION` in `app.js`, the `?v=` numbers in
`index.html`, `CACHE` in `sw.js`, and `version.json`. Phones check `version.json`
on opening and update themselves when it's newer.
