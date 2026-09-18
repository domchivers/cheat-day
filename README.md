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

When you change app files, bump the `?v=` numbers in `index.html` and
`CACHE` in `sw.js` so installed copies pick up the new version.
