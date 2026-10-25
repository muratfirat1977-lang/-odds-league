-- Odds League V5.4: sichere, einmalige virtuelle Wochenabrechnung
-- Supabase SQL Editor: ganze Datei ausfuehren. Loescht keine bisherigen Daten.
-- Erst NACH V5.3 (rangliste_ergebnisse_v5_3.sql) installieren.
begin;

-- Dauerhafte Abrechnungs-Snapshots: keine doppelte Buchung je Woche/Spieler.
create table if not exists public.odds_week_settlements (
  week_id bigint primary key references public.weeks(id) on delete restrict,
  settled_at timestamptz not null default now(),
  settled_by uuid not null references auth.users(id),
  participant_count integer not null check (participant_count > 0),
  jackpot_cents integer not null check (jackpot_cents >= 0),
  winner_count integer not null check (winner_count > 0)
);

create table if not exists public.odds_week_finances (
  week_id bigint not null references public.weeks(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete restrict,
  player_name text not null,
  points numeric not null,
  contribution_cents integer not null check (contribution_cents = 500),
  prize_cents integer not null default 0 check (prize_cents >= 0),
  primary key (week_id, user_id)
);
create index if not exists odds_week_finances_user_idx
  on public.odds_week_finances(user_id);

alter table public.odds_week_settlements enable row level security;
alter table public.odds_week_finances enable row level security;
revoke all on public.odds_week_settlements from public, anon, authenticated;
revoke all on public.odds_week_finances from public, anon, authenticated;

-- Eine Transaktion: alle Spieler belasten, Sieger gutschreiben, Woche sperren.
-- 0 Tipps => KEIN Eintrag und KEINE 5 EUR Belastung.
create or replace function public.odds_admin_settle_week(p_week_id bigint)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_settled boolean;
  v_label text;
  v_starts timestamptz;
  v_count integer := 0;
  v_winners integer := 0;
  v_max numeric;
  v_pool integer;
  v_base integer;
  v_rest integer;
  v_nth integer := 0;
  v_prize integer;
  v_paid integer := 0;
  v_rows jsonb := '[]'::jsonb;
  v_player record;
  v_item jsonb;
begin
  if not exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid())
      and p.role = 'admin' and p.active = true
  ) then
    raise exception 'Nur aktive Administratoren koennen eine Woche abrechnen.';
  end if;

  -- Row-Lock serialisiert gleichzeitige Abrechnungen.
  select w.settled, w.label, w.starts_at
    into v_settled, v_label, v_starts
  from public.weeks w
  where w.id = p_week_id
  for update;
  if not found then
    raise exception 'Spielwoche nicht gefunden.';
  end if;
  if v_settled is distinct from false or exists (
    select 1 from public.odds_week_settlements a where a.week_id = p_week_id
  ) then
    raise exception 'Die Woche wurde bereits abgerechnet.';
  end if;
  if not exists (select 1 from public.games g where g.week_id = p_week_id) then
    raise exception 'Keine Spiele in dieser Woche vorhanden.';
  end if;
  if exists (
    select 1 from public.games g
    where g.week_id = p_week_id and (g.result is null or g.result not in ('1','X','2'))
  ) then
    raise exception 'Bitte zuerst alle Spielergebnisse (1, X oder 2) eintragen.';
  end if;
  -- Testwochen duerfen absichtlich vor den Terminen abgerechnet werden.
  if v_label not ilike 'TESTWOCHE %' and exists (
    select 1 from public.games g
    where g.week_id = p_week_id and g.kickoff > now()
  ) then
    raise exception 'Echte Spielwochen duerfen erst nach allen Anpfiffen abgerechnet werden.';
  end if;

  -- Teilnehmerliste aus echten Tipps. Nur wer tippt, schuldet genau 500 Cent.
  -- Fuer jede Person wird der Punktewert als Snapshot gesichert.
  for v_player in
    select t.user_id as player_id, p.display_name as player_name,
      round(sum(
        case when g.result = t.choice
          then t.locked_quote::numeric * 10
          else 0::numeric end
      ),2) as points
    from public.tips t
    join public.games g on g.id = t.game_id
    join public.week_participants wp
      on wp.week_id = p_week_id and wp.user_id = t.user_id
    join public.profiles p on p.id = t.user_id
    where g.week_id = p_week_id
    group by t.user_id, p.display_name
    order by points desc, lower(p.display_name), t.user_id
  loop
    v_count := v_count+1;
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'id',v_player.player_id,
      'name',v_player.player_name,
      'points',v_player.points
    ));
    if v_max is null or v_player.points > v_max then
      v_max := v_player.points;
      v_winners := 1;
    elsif v_player.points = v_max then
      v_winners := v_winners+1;
    end if;
  end loop;

  if v_count = 0 then
    raise exception 'Ohne mindestens einen gespeicherten Tipp gibt es keine Wochenabrechnung.';
  end if;
  v_pool := v_count * 500;
  v_base := v_pool / v_winners;
  v_rest := v_pool % v_winners;

  insert into public.odds_week_settlements
    (week_id,settled_by,participant_count,jackpot_cents,winner_count)
  values (p_week_id,(select auth.uid()),v_count,v_pool,v_winners);

  for v_item in select value from jsonb_array_elements(v_rows)
  loop
    v_prize := 0;
    if (v_item->>'points')::numeric = v_max then
      v_nth := v_nth+1;
      v_prize := v_base + case when v_nth <= v_rest then 1 else 0 end;
    end if;
    insert into public.odds_week_finances
      (week_id,user_id,player_name,points,contribution_cents,prize_cents)
    values (
      p_week_id,
      (v_item->>'id')::uuid,
      v_item->>'name',
      (v_item->>'points')::numeric,
      500,
      v_prize
    );
    v_paid := v_paid+v_prize;
  end loop;

  if v_paid <> v_pool then
    raise exception 'Abrechnung abgebrochen: Jackpot-Summe stimmt nicht.';
  end if;
  update public.weeks set settled = true where id = p_week_id;
  return 'Woche abgerechnet: '||v_count||' Spieler, '||
    (v_pool::numeric/100)::text||' EUR Jackpot, '||v_winners||' Gewinner.';
end;
$$;

-- Einsicht in Abrechnung der eigenen Woche: aktive Admins oder Wochenmitglieder.
-- Die Endabrechnung ist fuer Teilnehmer transparent, jedoch ohne E-Mail-Adressen.
create or replace function public.odds_week_settlement(p_week_id bigint)
returns table (
  member_name text,
  total_points numeric,
  contribution_cents integer,
  prize_cents integer,
  net_cents integer
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.active = true
      and (
        p.role = 'admin'
        or exists (
          select 1 from public.week_participants wp
          where wp.week_id = p_week_id and wp.user_id = p.id
        )
      )
  ) then
    raise exception 'Kein Zugriff auf diese Wochenabrechnung.';
  end if;
  return query
    select f.player_name, f.points,
           f.contribution_cents, f.prize_cents,
           f.prize_cents-f.contribution_cents
    from public.odds_week_finances f
    where f.week_id = p_week_id
    order by f.prize_cents desc, f.points desc, lower(f.player_name), f.user_id;
end;
$$;

-- Dein virtuelles Guthaben aus ALLEN endgueltig abgerechneten Wochen.
-- Darf negativ sein: dann besteht rechnerisch eine offene Teilnahmeforderung.
create or replace function public.odds_my_wallet()
returns table (
  weeks_played integer,
  paid_cents bigint,
  won_cents bigint,
  balance_cents bigint
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.active = true
  ) then
    raise exception 'Nur aktive Mitglieder duerfen ihr Gewinnkonto sehen.';
  end if;
  return query
    select count(f.week_id)::integer,
      coalesce(sum(f.contribution_cents),0)::bigint,
      coalesce(sum(f.prize_cents),0)::bigint,
      coalesce(sum(f.prize_cents-f.contribution_cents),0)::bigint
    from public.odds_week_finances f
    where f.user_id = (select auth.uid());
end;
$$;

revoke execute on function public.odds_admin_settle_week(bigint)
  from public, anon, authenticated;
revoke execute on function public.odds_week_settlement(bigint)
  from public, anon, authenticated;
revoke execute on function public.odds_my_wallet()
  from public, anon, authenticated;
grant execute on function public.odds_admin_settle_week(bigint) to authenticated;
grant execute on function public.odds_week_settlement(bigint) to authenticated;
grant execute on function public.odds_my_wallet() to authenticated;
commit;

select proname as funktion, prosecdef as security_definer
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname in ('odds_admin_settle_week','odds_week_settlement','odds_my_wallet')
order by proname;
