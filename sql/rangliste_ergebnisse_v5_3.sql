-- Odds League V5.3 – gemeinsame Rangliste und geschuetzte Ergebnisverwaltung
-- Einmal in Supabase -> SQL Editor ausfuehren (erneut ausfuehrbar).
-- Bestehende Tipps, Wochen und Benutzer werden NICHT geloescht.
begin;

-- Nachvollziehbare Aenderungshistorie fuer echte Supabase-Ergebnisse.
create table if not exists public.odds_result_changes (
  id bigint generated always as identity primary key,
  game_id bigint not null references public.games(id) on delete cascade,
  admin_id uuid not null references auth.users(id),
  old_result text,
  new_result text,
  reason text not null,
  changed_at timestamptz not null default now()
);
create index if not exists odds_result_changes_game_time_idx
  on public.odds_result_changes (game_id, changed_at desc);
alter table public.odds_result_changes enable row level security;
revoke all on public.odds_result_changes from public, anon, authenticated;

-- Gemeinsame Tabelle: nur aktive, angemeldete Wochenteilnehmer und Admins.
-- Ohne gespeicherten Tipp keine Teilnahme, keinen Einsatz und keinen Ranglistenplatz.
-- 1 bis 10 gespeicherte Tipps kosten zusammen nur EINMAL 5 EUR pro Spielwoche.
-- PRIVAT: Tippauswahl und Einzelquoten anderer Spieler werden nicht ausgegeben.
create or replace function public.odds_week_standings(p_week_id bigint)
returns table (
  member_id uuid,
  member_name text,
  tip_count integer,
  correct_count integer,
  total_points numeric
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
          select 1 from public.week_participants mine
          where mine.week_id = p_week_id and mine.user_id = p.id
        )
      )
  ) then
    raise exception 'Kein Zugriff auf die Rangliste dieser Spielwoche.';
  end if;

  return query
  select
    p.id,
    p.display_name::text,
    count(t.game_id)::integer,
    count(t.game_id) filter (where g.result is not null and g.result = t.choice)::integer,
    coalesce(
      round(sum(case when g.result is not null and g.result = t.choice
        then t.locked_quote::numeric * 10 else 0::numeric end), 2),
      0::numeric
    ) as score
  from public.week_participants wp
  join public.profiles p on p.id = wp.user_id
  left join public.games g on g.week_id = wp.week_id
  left join public.tips t on t.game_id = g.id and t.user_id = wp.user_id
  where wp.week_id = p_week_id
  group by p.id, p.display_name
  having count(t.game_id) >= 1
  order by 5 desc, lower(p.display_name), p.id;
end;
$$;

-- Nur aktive Administratoren duerfen 1-X-2 Ergebnisse eintragen.
-- Sicherheitsregel fuer echte Wochen: nicht vor Anpfiff. Nur TEST-Wochen
-- koennen fuer Entwicklung und Demonstration frueher bewertet werden.
create or replace function public.odds_admin_save_result(
  p_game_id bigint,
  p_result text,
  p_reason text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old_result text;
  v_kickoff timestamptz;
  v_week_label text;
  v_settled boolean;
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = (select auth.uid()) and a.role = 'admin' and a.active = true
  ) then
    raise exception 'Nur ein aktiver Administrator darf Ergebnisse aendern.';
  end if;

  if p_game_id is null or (p_result is not null and p_result not in ('1','X','2')) then
    raise exception 'Ungueltiges Ergebnis. Erlaubt: 1, X, 2 oder offen.';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 5 and 250 then
    raise exception 'Bitte eine Begruendung (5 bis 250 Zeichen) eintragen.';
  end if;

  select g.result, g.kickoff, w.label, w.settled
    into v_old_result, v_kickoff, v_week_label, v_settled
  from public.games g
  join public.weeks w on w.id = g.week_id
  where g.id = p_game_id
  for update of g;

  if not found then
    raise exception 'Spiel nicht gefunden.';
  end if;
  if v_settled is distinct from false then
    raise exception 'Diese Spielwoche ist bereits abgerechnet.';
  end if;
  if now() < v_kickoff and v_week_label not ilike 'TESTWOCHE %' then
    raise exception 'Ergebnisse echter Spiele duerfen erst nach Anpfiff eingetragen werden.';
  end if;
  if v_old_result is not distinct from p_result then
    return 'Keine Aenderung: Ergebnis ist bereits so gespeichert.';
  end if;

  update public.games set result = p_result where id = p_game_id;
  insert into public.odds_result_changes
    (game_id, admin_id, old_result, new_result, reason)
  values
    (p_game_id, (select auth.uid()), v_old_result, p_result, btrim(p_reason));
  return 'Ergebnis gespeichert und protokolliert.';
end;
$$;

-- Verlauf ohne E-Mail-Adressen, nur fuer aktive Admins.
create or replace function public.odds_admin_result_history(p_week_id bigint)
returns table (
  changed_at timestamptz,
  match_label text,
  old_result text,
  new_result text,
  reason text,
  admin_name text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = (select auth.uid()) and a.role = 'admin' and a.active = true
  ) then
    raise exception 'Keine Administratorberechtigung.';
  end if;
  return query
    select c.changed_at,
      (g.home_team || ' – ' || g.away_team)::text,
      c.old_result,
      c.new_result,
      c.reason,
      p.display_name::text
    from public.odds_result_changes c
    join public.games g on g.id = c.game_id
    join public.profiles p on p.id = c.admin_id
    where g.week_id = p_week_id
    order by c.changed_at desc, c.id desc
    limit 25;
end;
$$;

revoke execute on function public.odds_week_standings(bigint)
  from public, anon, authenticated;
revoke execute on function public.odds_admin_save_result(bigint,text,text)
  from public, anon, authenticated;
revoke execute on function public.odds_admin_result_history(bigint)
  from public, anon, authenticated;
grant execute on function public.odds_week_standings(bigint) to authenticated;
grant execute on function public.odds_admin_save_result(bigint,text,text) to authenticated;
grant execute on function public.odds_admin_result_history(bigint) to authenticated;

commit;

select proname as funktion, prosecdef as security_definer
from pg_proc
where pronamespace='public'::regnamespace
  and proname in ('odds_week_standings','odds_admin_save_result',
                  'odds_admin_result_history')
order by proname;
