-- PokéBonk Ranked V2: secure admin controls.
-- Run once in Supabase SQL Editor after the existing admin and locker migrations.

create table if not exists public.player_rp_adjustments (
  id bigint generated always as identity primary key,
  player_id uuid not null references auth.users(id) on delete cascade,
  week_key text not null,
  amount numeric(10,2) not null check (amount <> 0),
  reason text not null,
  admin_id uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
create index if not exists player_rp_adjustments_week_player_idx
  on public.player_rp_adjustments(week_key, player_id);
alter table public.player_rp_adjustments enable row level security;
revoke all on public.player_rp_adjustments from public, anon, authenticated;

create table if not exists public.admin_ranked_reset_archive (
  id bigint generated always as identity primary key,
  reset_week text not null,
  record_type text not null check (record_type in ('run','rp_adjustment')),
  record_data jsonb not null,
  archived_by uuid not null references auth.users(id),
  archived_at timestamptz not null default now()
);
alter table public.admin_ranked_reset_archive enable row level security;
revoke all on public.admin_ranked_reset_archive from public, anon, authenticated;

create or replace function public.admin_adjust_rp(p_target uuid, p_amount numeric, p_reason text)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare v_admin uuid; v_week text; v_total numeric;
begin
  v_admin := public.require_pokebonk_admin();
  if p_target is null or p_amount is null or p_amount = 0 or abs(p_amount) > 1000000 then
    raise exception 'Enter a non-zero RP adjustment between -1,000,000 and 1,000,000.';
  end if;
  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'A reason of at least 3 characters is required.';
  end if;
  if not exists (select 1 from public.player_profiles where id = p_target) then
    raise exception 'Player not found.';
  end if;
  v_week := to_char(current_date, 'IYYY-"W"IW');
  insert into public.player_rp_adjustments(player_id, week_key, amount, reason, admin_id)
  values (p_target, v_week, p_amount, trim(p_reason), v_admin);
  insert into public.admin_audit_log(admin_id,target_id,action,details)
  values (v_admin,p_target,'adjust_rp',jsonb_build_object('amount',p_amount,'week_key',v_week,'reason',trim(p_reason)));
  select coalesce(sum(r.rp_earned),0)+coalesce((select sum(a.amount) from public.player_rp_adjustments a where a.player_id=p_target and a.week_key=v_week),0)
    into v_total
  from public.player_runs r where r.player_id=p_target and r.week_key=v_week;
  return v_total;
end;
$$;

create or replace function public.admin_get_players_v2(p_search text default '', p_limit integer default 100)
returns table(player_id uuid, username text, rp numeric, legacy_coins bigint, is_admin boolean, is_banned boolean, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare v_admin uuid; v_week text;
begin
  v_admin := public.require_pokebonk_admin();
  v_week := to_char(current_date, 'IYYY-"W"IW');
  return query
  select p.id,p.username,
    coalesce(r.run_rp,0)+coalesce(a.adjusted_rp,0),
    coalesce(w.legacy_coins,0),coalesce(w.is_admin,false),coalesce(w.is_banned,false),p.created_at
  from public.player_profiles p
  left join public.player_wallets w on w.user_id=p.id
  left join (
    select pr.player_id,sum(pr.rp_earned) as run_rp
    from public.player_runs pr where pr.week_key=v_week group by pr.player_id
  ) r on r.player_id=p.id
  left join (
    select pa.player_id,sum(pa.amount) as adjusted_rp
    from public.player_rp_adjustments pa where pa.week_key=v_week group by pa.player_id
  ) a on a.player_id=p.id
  where (coalesce(trim(p_search),'')='' or p.username ilike '%'||trim(p_search)||'%')
  order by coalesce(w.is_admin,false) desc,p.username
  limit greatest(1,least(coalesce(p_limit,100),200));
end;
$$;

create or replace function public.get_global_leaderboard_v2()
returns table(username text, rank_name text, weekly_runs bigint, weekly_rp numeric)
language sql
stable
security definer
set search_path = public
as $$
  with current_week as (
    select to_char(current_date, 'IYYY-"W"IW') as week_key
  ), run_totals as (
    select r.player_id,count(*)::bigint as runs,sum(r.rp_earned)::numeric as rp
    from public.player_runs r,current_week w
    where r.week_key=w.week_key group by r.player_id
  ), adjustments as (
    select a.player_id,sum(a.amount)::numeric as rp
    from public.player_rp_adjustments a,current_week w
    where a.week_key=w.week_key group by a.player_id
  ), totals as (
    select p.username,coalesce(rt.runs,0)::bigint as weekly_runs,
      (coalesce(rt.rp,0)+coalesce(ad.rp,0))::numeric as weekly_rp
    from public.player_profiles p
    left join public.player_wallets w on w.user_id=p.id
    left join run_totals rt on rt.player_id=p.id
    left join adjustments ad on ad.player_id=p.id
    where coalesce(w.is_banned,false)=false
      and (coalesce(rt.runs,0)>0 or coalesce(ad.rp,0)<>0)
  )
  select t.username,
    case when t.weekly_rp>=15000 then 'Grandmaster'
         when t.weekly_rp>=9000 then 'Master'
         when t.weekly_rp>=5500 then 'Diamond'
         when t.weekly_rp>=3000 then 'Platinum'
         when t.weekly_rp>=1500 then 'Gold'
         when t.weekly_rp>=500 then 'Silver'
         else 'Bronze' end,
    t.weekly_runs,t.weekly_rp
  from totals t order by t.weekly_rp desc,t.weekly_runs desc,t.username limit 100;
$$;

create or replace function public.admin_reset_ranked_week()
returns table(reset_week text, runs_archived bigint, adjustments_archived bigint)
language plpgsql
security definer
set search_path = public
as $$
declare v_admin uuid; v_week text; v_runs bigint; v_adjustments bigint;
begin
  v_admin := public.require_pokebonk_admin();
  v_week := to_char(current_date, 'IYYY-"W"IW');
  insert into public.admin_ranked_reset_archive(reset_week,record_type,record_data,archived_by)
  select v_week,'run',to_jsonb(r),v_admin
  from public.player_runs r where r.week_key=v_week;
  get diagnostics v_runs = row_count;
  insert into public.admin_ranked_reset_archive(reset_week,record_type,record_data,archived_by)
  select v_week,'rp_adjustment',to_jsonb(a),v_admin
  from public.player_rp_adjustments a where a.week_key=v_week;
  get diagnostics v_adjustments = row_count;
  delete from public.player_runs where week_key=v_week;
  delete from public.player_rp_adjustments where week_key=v_week;
  insert into public.admin_audit_log(admin_id,target_id,action,details)
  values(v_admin,null,'ranked_week_reset',jsonb_build_object('week_key',v_week,'runs_archived',v_runs,'adjustments_archived',v_adjustments));
  return query select v_week,v_runs,v_adjustments;
end;
$$;

create or replace function public.admin_get_audit_log(p_limit integer default 30)
returns table(id bigint, action text, details jsonb, created_at timestamptz, target_username text)
language plpgsql
security definer
set search_path = public
as $$
declare v_admin uuid;
begin
  v_admin := public.require_pokebonk_admin();
  return query
  select a.id,a.action,a.details,a.created_at,p.username
  from public.admin_audit_log a
  left join public.player_profiles p on p.id=a.target_id
  order by a.created_at desc
  limit greatest(1,least(coalesce(p_limit,30),100));
end;
$$;

revoke all on function public.admin_adjust_rp(uuid,numeric,text) from public,anon;
revoke all on function public.admin_get_players_v2(text,integer) from public,anon;
revoke all on function public.get_global_leaderboard_v2() from public;
revoke all on function public.admin_reset_ranked_week() from public,anon;
revoke all on function public.admin_get_audit_log(integer) from public,anon;
grant execute on function public.admin_adjust_rp(uuid,numeric,text) to authenticated;
grant execute on function public.admin_get_players_v2(text,integer) to authenticated;
grant execute on function public.get_global_leaderboard_v2() to anon,authenticated;
grant execute on function public.admin_reset_ranked_week() to authenticated;
grant execute on function public.admin_get_audit_log(integer) to authenticated;
