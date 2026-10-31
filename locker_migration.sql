-- PokéBonk Ranked: account-synced cosmetic locker
-- Run once in Supabase SQL Editor.
create table if not exists public.player_cosmetic_loadout (
  player_id uuid not null references auth.users(id) on delete cascade,
  category text not null check (category in ('Nameplates','Auras','Frames','Themes','Titles','Badges')),
  cosmetic_id text not null,
  updated_at timestamptz not null default now(),
  primary key (player_id, category)
);
alter table public.player_cosmetic_loadout enable row level security;
revoke all on public.player_cosmetic_loadout from anon, authenticated, public;

create or replace function public.get_my_pokebonk_loadout()
returns table(category text, cosmetic_id text)
language sql
security definer
set search_path = public
as $$
  select l.category, l.cosmetic_id
  from public.player_cosmetic_loadout l
  where l.player_id = auth.uid()
  order by l.category;
$$;

create or replace function public.set_pokebonk_equipped(p_category text, p_cosmetic_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if p_category not in ('Nameplates','Auras','Frames','Themes','Titles','Badges') then
    raise exception 'Invalid cosmetic category.';
  end if;
  if p_cosmetic_id is null then
    delete from public.player_cosmetic_loadout
    where player_id = auth.uid() and category = p_category;
    return;
  end if;
  if not exists (
    select 1 from public.player_cosmetics pc
    where pc.player_id = auth.uid() and pc.cosmetic_id = p_cosmetic_id
  ) then
    raise exception 'You do not own this cosmetic.';
  end if;
  if (p_category = 'Nameplates' and split_part(p_cosmetic_id, '-', 1) <> 'nameplate')
     or (p_category = 'Auras' and split_part(p_cosmetic_id, '-', 1) <> 'aura')
     or (p_category = 'Frames' and split_part(p_cosmetic_id, '-', 1) <> 'frame')
     or (p_category = 'Themes' and split_part(p_cosmetic_id, '-', 1) <> 'theme')
     or (p_category = 'Titles' and split_part(p_cosmetic_id, '-', 1) <> 'title')
     or (p_category = 'Badges' and split_part(p_cosmetic_id, '-', 1) <> 'badge') then
    raise exception 'Cosmetic does not match the selected category.';
  end if;
  insert into public.player_cosmetic_loadout(player_id, category, cosmetic_id, updated_at)
  values (auth.uid(), p_category, p_cosmetic_id, now())
  on conflict (player_id, category)
  do update set cosmetic_id = excluded.cosmetic_id, updated_at = now();
end;
$$;

revoke all on function public.get_my_pokebonk_loadout() from public, anon;
revoke all on function public.set_pokebonk_equipped(text,text) from public, anon;
grant execute on function public.get_my_pokebonk_loadout() to authenticated;
grant execute on function public.set_pokebonk_equipped(text,text) to authenticated;


-- Public, read-only cosmetic display data for leaderboard nameplates/titles/badges.
-- Only equipped cosmetic IDs and public usernames are exposed, never ownership history or account data.
create or replace function public.get_public_pokebonk_loadouts()
returns table(username text, category text, cosmetic_id text)
language sql
stable
security definer
set search_path = public
as $$
  select p.username, l.category, l.cosmetic_id
  from public.player_cosmetic_loadout l
  join public.player_profiles p on p.id = l.player_id
  left join public.player_wallets w on w.user_id = l.player_id
  where coalesce(w.is_banned, false) = false
  order by p.username, l.category;
$$;

revoke all on function public.get_public_pokebonk_loadouts() from public;
grant execute on function public.get_public_pokebonk_loadouts() to anon, authenticated;
