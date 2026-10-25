-- Odds League V5.5: Prepaid-Guthaben + Admin-Aufladung + neue Spielwoche
-- Voraussetzung: V5.4 SQL bereits ausgefuehrt.
-- Einmal in Supabase SQL Editor vollstaendig ausfuehren. Bestehende Historie bleibt erhalten.
begin;

-- Kontostand in Cent (vorherige Altwochen koennen historisch negativ sein).
create table if not exists public.odds_wallet_accounts (
  user_id uuid primary key references public.profiles(id) on delete restrict,
  balance_cents bigint not null default 0,
  updated_at timestamptz not null default now()
);
create table if not exists public.odds_wallet_entries (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete restrict,
  week_id bigint references public.weeks(id) on delete restrict,
  kind text not null check (kind in
    ('legacy_stake','legacy_prize','opening_stake','topup','stake','stake_refund','prize')),
  amount_cents bigint not null check (amount_cents <> 0),
  reason text not null,
  changed_by uuid references auth.users(id),
  event_key text unique,
  created_at timestamptz not null default now()
);
create index if not exists odds_wallet_entries_person_idx
  on public.odds_wallet_entries(user_id,created_at desc);

-- Aktive Eintrittsgebuehr je Woche; bei letztem geloeschten Tipp wird sie zurueckgebucht.
create table if not exists public.odds_week_stakes (
  week_id bigint not null references public.weeks(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete restrict,
  active boolean not null default false,
  primary key (week_id,user_id)
);

alter table public.odds_wallet_accounts enable row level security;
alter table public.odds_wallet_entries enable row level security;
alter table public.odds_week_stakes enable row level security;
revoke all on public.odds_wallet_accounts from public,anon,authenticated;
revoke all on public.odds_wallet_entries from public,anon,authenticated;
revoke all on public.odds_week_stakes from public,anon,authenticated;

-- Einmaliger Uebertrag der bisherigen abgeschlossenen Testwochen (auch Minus-Salden):
-- Es werden keine schon vorhandenen Konten ueberschrieben.
insert into public.odds_wallet_accounts(user_id,balance_cents)
select p.id,coalesce(sum(f.prize_cents-f.contribution_cents),0)::bigint
from public.profiles p
left join public.odds_week_finances f on f.user_id=p.id
group by p.id
on conflict(user_id) do nothing;

-- Alte Buchungen nachvollziehbar uebernehmen, bei erneutem RUN keine Duplikate.
insert into public.odds_wallet_entries(user_id,week_id,kind,amount_cents,reason,event_key)
select f.user_id,f.week_id,'legacy_stake',(-f.contribution_cents)::bigint,
       'Uebernommener Wocheneinsatz', 'legacy-fee:'||f.week_id||':'||f.user_id
from public.odds_week_finances f
on conflict(event_key) do nothing;
insert into public.odds_wallet_entries(user_id,week_id,kind,amount_cents,reason,event_key)
select f.user_id,f.week_id,'legacy_prize',f.prize_cents::bigint,
       'Uebernommener Wochengewinn', 'legacy-prize:'||f.week_id||':'||f.user_id
from public.odds_week_finances f where f.prize_cents>0
on conflict(event_key) do nothing;

-- Falls vor der Migration noch NICHT abgerechnete Wochen Tipps besitzen,
-- diese Beteiligungen einmalig als offene 5-EUR-Buchungen uebernehmen.
with new_stakes as (
  insert into public.odds_week_stakes(week_id,user_id,active)
  select distinct g.week_id,t.user_id,true
  from public.tips t
  join public.games g on g.id=t.game_id
  join public.weeks w on w.id=g.week_id and w.settled=false
  on conflict(week_id,user_id) do nothing
  returning week_id,user_id
), booked as (
  insert into public.odds_wallet_entries(user_id,week_id,kind,amount_cents,reason,event_key)
  select user_id,week_id,'opening_stake',-500,'Bestehender Tipp bei Umstellung',
         'opening-fee:'||week_id||':'||user_id from new_stakes
  returning user_id
)
update public.odds_wallet_accounts a
set balance_cents=a.balance_cents-500*b.n,
    updated_at=now()
from (select user_id,count(*)::bigint as n from booked group by user_id) b
where a.user_id=b.user_id;

-- Erste Tippabgabe pro Woche: 500 Cent sofort abbuchen.
-- Ein Wallet-Row-Lock und die Week-Stake-Sperre verhindern Doppelbuchungen.
create or replace function public.odds_wallet_on_tip_insert()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare
  v_week bigint;
  v_settled boolean;
  v_active boolean;
begin
  select g.week_id,w.settled into v_week,v_settled
  from public.games g join public.weeks w on w.id=g.week_id
  where g.id=new.game_id;
  if not found or v_settled is distinct from false then
    raise exception 'Spielwoche nicht vorhanden oder bereits abgerechnet.';
  end if;
  insert into public.odds_wallet_accounts(user_id,balance_cents)
  values(new.user_id,0) on conflict(user_id) do nothing;

  -- Kontosperre serialisiert Tippabgaben derselben Person auch bei Parallelzugriff.
  perform 1 from public.odds_wallet_accounts a
  where a.user_id=new.user_id for update;
  insert into public.odds_week_stakes(week_id,user_id,active)
  values(v_week,new.user_id,false)
  on conflict(week_id,user_id) do nothing;
  select s.active into v_active from public.odds_week_stakes s
  where s.week_id=v_week and s.user_id=new.user_id for update;
  if not v_active then
    update public.odds_wallet_accounts a
    set balance_cents=a.balance_cents-500,updated_at=now()
    where a.user_id=new.user_id and a.balance_cents>=500;
    if not found then
      raise exception 'Nicht genug Guthaben: Fuer die erste Tippabgabe dieser Woche sind mindestens 5,00 EUR erforderlich. Bitte den Admin um Aufladung bitten.';
    end if;
    update public.odds_week_stakes
    set active=true where week_id=v_week and user_id=new.user_id;
    insert into public.odds_wallet_entries
      (user_id,week_id,kind,amount_cents,reason)
    values(new.user_id,v_week,'stake',-500,'5 EUR Wocheneinsatz (erster Tipp)');
  end if;
  return new;
end;
$$;

create or replace function public.odds_wallet_on_tip_delete()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare
  v_week bigint;
  v_settled boolean;
  v_active boolean;
begin
  select g.week_id,w.settled into v_week,v_settled
  from public.games g join public.weeks w on w.id=g.week_id
  where g.id=old.game_id;
  if v_settled is distinct from false then
    raise exception 'Eine abgerechnete Woche kann nicht mehr geaendert werden.';
  end if;
  -- Wenn der Spieler noch einen anderen Tipp in der Woche besitzt, keine Erstattung.
  if exists (
    select 1 from public.tips t join public.games g on g.id=t.game_id
    where t.user_id=old.user_id and g.week_id=v_week
  ) then return old; end if;

  perform 1 from public.odds_wallet_accounts a
  where a.user_id=old.user_id for update;
  select s.active into v_active from public.odds_week_stakes s
  where s.week_id=v_week and s.user_id=old.user_id for update;
  if v_active then
    update public.odds_week_stakes set active=false
      where week_id=v_week and user_id=old.user_id;
    update public.odds_wallet_accounts
      set balance_cents=balance_cents+500,updated_at=now()
      where user_id=old.user_id;
    insert into public.odds_wallet_entries
      (user_id,week_id,kind,amount_cents,reason)
    values(old.user_id,v_week,'stake_refund',500,'Rueckzahlung nach Entfernen des letzten Tipps');
  end if;
  return old;
end;
$$;

-- Kontoidentitaet bei Tipp-Aenderungen unveraenderlich halten.
create or replace function public.odds_wallet_on_tip_update()
returns trigger
language plpgsql security definer set search_path=''
as $$
begin
  if new.user_id is distinct from old.user_id
     or new.game_id is distinct from old.game_id then
    raise exception 'Spieler und Spiel eines Tipps duerfen nicht umgeschrieben werden.';
  end if;
  return new;
end;
$$;

drop trigger if exists odds_tip_prepaid_insert on public.tips;
create trigger odds_tip_prepaid_insert before insert on public.tips
for each row execute function public.odds_wallet_on_tip_insert();
drop trigger if exists odds_tip_prepaid_delete on public.tips;
create trigger odds_tip_prepaid_delete after delete on public.tips
for each row execute function public.odds_wallet_on_tip_delete();
drop trigger if exists odds_tip_prepaid_update on public.tips;
create trigger odds_tip_prepaid_update before update on public.tips
for each row execute function public.odds_wallet_on_tip_update();

-- Bei finaler Abrechnung ist der Wocheneinsatz bereits gebucht:
-- Nur der PREIS wird als Guthaben verbucht, niemals nochmals -5 EUR.
create or replace function public.odds_wallet_on_finance_insert()
returns trigger
language plpgsql security definer set search_path=''
as $$
begin
  if not exists (
    select 1 from public.odds_week_stakes s
    where s.week_id=new.week_id and s.user_id=new.user_id and s.active=true
  ) then
    raise exception 'Wochenabrechnung abgebrochen: Spieler % besitzt keinen verbuchten Wocheneinsatz.',new.user_id;
  end if;
  if new.prize_cents>0 then
    update public.odds_wallet_accounts
    set balance_cents=balance_cents+new.prize_cents, updated_at=now()
    where user_id=new.user_id;
    if not found then raise exception 'Konto des Gewinners nicht gefunden.'; end if;
    insert into public.odds_wallet_entries
      (user_id,week_id,kind,amount_cents,reason)
    values(new.user_id,new.week_id,'prize',new.prize_cents,'Wochengewinn');
  end if;
  return new;
end;
$$;
drop trigger if exists odds_finance_wallet_credit on public.odds_week_finances;
create trigger odds_finance_wallet_credit after insert on public.odds_week_finances
for each row execute function public.odds_wallet_on_finance_insert();

-- Konto inkl. Guthaben, Einzahlungen und aller Wochenbuchungen.
-- Alte V5.4-Aufrufsignatur bleibt erhalten.
create or replace function public.odds_my_wallet()
returns table (
  weeks_played integer,paid_cents bigint,won_cents bigint,balance_cents bigint
)
language plpgsql security definer set search_path=''
as $$
begin
  if not exists (
    select 1 from public.profiles p where p.id=(select auth.uid()) and p.active=true
  ) then raise exception 'Kein aktives Mitgliederkonto.'; end if;
  return query
  select
    (select count(*)::integer from public.odds_week_finances f
       where f.user_id=(select auth.uid())),
    coalesce((select -sum(x.amount_cents)::bigint from public.odds_wallet_entries x
      where x.user_id=(select auth.uid()) and x.kind in
        ('legacy_stake','opening_stake','stake','stake_refund')),0)::bigint,
    coalesce((select sum(x.amount_cents)::bigint from public.odds_wallet_entries x
      where x.user_id=(select auth.uid()) and x.kind in ('legacy_prize','prize')),0)::bigint,
    coalesce((select a.balance_cents from public.odds_wallet_accounts a
      where a.user_id=(select auth.uid())),0)::bigint;
end;
$$;

create or replace function public.odds_my_wallet_details()
returns table(credit_cents bigint, balance_cents bigint,can_start_week boolean)
language plpgsql security definer set search_path=''
as $$
begin
  if not exists (select 1 from public.profiles p
    where p.id=(select auth.uid()) and p.active=true) then
      raise exception 'Kein Zugriff auf dieses Konto.';
  end if;
  return query
  select coalesce((select sum(e.amount_cents)::bigint
          from public.odds_wallet_entries e where e.user_id=(select auth.uid())
          and e.kind='topup'),0)::bigint,
         coalesce(a.balance_cents,0)::bigint,
         (coalesce(a.balance_cents,0)>=500)
  from (select (select auth.uid()) as id) u
  left join public.odds_wallet_accounts a on a.user_id=u.id;
end;
$$;

-- Eigener Buchungsverlauf (keine privaten E-Mail-Adressen).
create or replace function public.odds_my_wallet_history()
returns table(booked_at timestamptz,kind text,amount_cents bigint,reason text,week_name text)
language plpgsql security definer set search_path=''
as $$
begin
  if not exists (select 1 from public.profiles p
    where p.id=(select auth.uid()) and p.active=true) then
      raise exception 'Kein Zugriff auf Buchungen.';
  end if;
  return query
    select e.created_at,e.kind,e.amount_cents,e.reason,w.label::text
    from public.odds_wallet_entries e
    left join public.weeks w on w.id=e.week_id
    where e.user_id=(select auth.uid())
    order by e.created_at desc,e.id desc limit 50;
end;
$$;

-- Nur aktive Admins duerfen Guthaben VERGEBEN; nie direkt ueber den Browser.
create or replace function public.odds_admin_wallet_members()
returns table(member_id uuid,member_name text,balance_cents bigint,member_active boolean)
language plpgsql security definer set search_path=''
as $$
begin
  if not exists(select 1 from public.profiles p where p.id=(select auth.uid())
    and p.role='admin' and p.active=true) then
    raise exception 'Nur Administratoren duerfen Spielerkonten einsehen.';
  end if;
  return query
  select p.id,p.display_name::text,coalesce(a.balance_cents,0)::bigint,p.active
  from public.profiles p left join public.odds_wallet_accounts a on a.user_id=p.id
  order by lower(p.display_name),p.id;
end;
$$;

create or replace function public.odds_admin_add_credit(
  p_member_id uuid,p_amount_cents integer,p_reason text
)
returns text
language plpgsql security definer set search_path=''
as $$
declare v_name text;
begin
  if not exists(select 1 from public.profiles p where p.id=(select auth.uid())
    and p.role='admin' and p.active=true) then
    raise exception 'Nur der Administrator darf Guthaben aufladen.';
  end if;
  if p_amount_cents is null or p_amount_cents<1 or p_amount_cents>100000 then
    raise exception 'Bitte einen positiven Betrag bis 1000,00 EUR waehlen.';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 3 and 160 then
    raise exception 'Eine Begruendung (3 bis 160 Zeichen) ist Pflicht.';
  end if;
  select p.display_name into v_name from public.profiles p
  where p.id=p_member_id for update;
  if not found then raise exception 'Mitglied nicht gefunden.';end if;
  insert into public.odds_wallet_accounts(user_id,balance_cents)
  values(p_member_id,0) on conflict(user_id) do nothing;
  update public.odds_wallet_accounts a
    set balance_cents=balance_cents+p_amount_cents,updated_at=now()
    where a.user_id=p_member_id;
  insert into public.odds_wallet_entries
    (user_id,kind,amount_cents,reason,changed_by)
  values(p_member_id,'topup',p_amount_cents,btrim(p_reason),(select auth.uid()));
  return 'Guthaben fuer '||v_name||' um '||(p_amount_cents::numeric/100)::text||' EUR aufgeladen.';
end;
$$;

-- Neue Wochen incl. Spiele nur durch Admin.
-- p_games: JSON Array [{league,home_team,away_team,kickoff,quote_1,quote_x,quote_2}]
create or replace function public.odds_admin_create_week(
  p_label text,p_starts_at timestamptz,p_ends_at timestamptz,p_games jsonb
)
returns bigint
language plpgsql security definer set search_path=''
as $$
declare v_week_id bigint; v_game jsonb; v_kickoff timestamptz;
  v_league text;v_home text;v_away text;v_q1 numeric;v_qx numeric;v_q2 numeric;
begin
  if not exists (select 1 from public.profiles p where p.id=(select auth.uid())
    and p.role='admin' and p.active=true) then
    raise exception 'Nur Administratoren duerfen Spielwochen anlegen.';
  end if;
  if p_label is null or length(btrim(p_label)) not between 5 and 80
     or p_starts_at is null or p_ends_at is null
     or p_starts_at>=p_ends_at or p_ends_at<=now()
     or p_ends_at>p_starts_at+interval '21 days' then
    raise exception 'Ungueltiger Wochenname, Zeitraum oder Enddatum.';
  end if;
  if p_games is null or jsonb_typeof(p_games)<>'array'
     or jsonb_array_length(p_games) not between 1 and 24 then
    raise exception 'Bitte 1 bis 24 Spiele angeben.';
  end if;
  if exists(select 1 from public.weeks w where lower(w.label)=lower(btrim(p_label))) then
    raise exception 'Eine Spielwoche mit diesem Namen existiert bereits.';
  end if;
  insert into public.weeks(label,starts_at,ends_at,settled)
  values(btrim(p_label),p_starts_at,p_ends_at,false) returning id into v_week_id;

  for v_game in select value from jsonb_array_elements(p_games)
  loop
    if jsonb_typeof(v_game)<>'object' then
      raise exception 'Jedes Spiel muss ein Objekt sein.';
    end if;
    v_league=v_game->>'league';
    v_home=btrim(v_game->>'home_team');
    v_away=btrim(v_game->>'away_team');
    v_kickoff=(v_game->>'kickoff')::timestamptz;
    v_q1=(v_game->>'quote_1')::numeric;
    v_qx=(v_game->>'quote_x')::numeric;
    v_q2=(v_game->>'quote_2')::numeric;
    if v_league not in ('de','en','es','tr')
       or length(v_home) not between 2 and 70
       or length(v_away) not between 2 and 70
       or v_home=v_away
       or v_kickoff<p_starts_at or v_kickoff>p_ends_at
       or (p_label not ilike 'TESTWOCHE %' and v_kickoff<=now()+interval '5 minutes')
       or v_q1<=1 or v_qx<=1 or v_q2<=1
       or v_q1>999 or v_qx>999 or v_q2>999 then
      raise exception 'Ungueltige Liga, Begegnung, Anpfiff oder Quote.';
    end if;
    insert into public.games
      (week_id,league,home_team,away_team,kickoff,quote_1,quote_x,quote_2)
    values(v_week_id,v_league,v_home,v_away,v_kickoff,v_q1,v_qx,v_q2);
  end loop;
  -- Der Admin kann mitspielen, benoetigt aber wie jeder Guthaben fuer den ersten Tipp.
  insert into public.week_participants(week_id,user_id)
  values(v_week_id,(select auth.uid())) on conflict do nothing;
  return v_week_id;
end;
$$;

-- Alle neuen Funktionen sind nur fuer eingeloggte Benutzer aufrufbar;
-- jede Admin-RPC prueft zusaetzlich Rolle und Aktivierung auf dem Server.
revoke execute on function public.odds_wallet_on_tip_insert() from public,anon,authenticated;
revoke execute on function public.odds_wallet_on_tip_delete() from public,anon,authenticated;
revoke execute on function public.odds_wallet_on_tip_update() from public,anon,authenticated;
revoke execute on function public.odds_wallet_on_finance_insert() from public,anon,authenticated;
revoke execute on function public.odds_my_wallet_details() from public,anon,authenticated;
revoke execute on function public.odds_my_wallet_history() from public,anon,authenticated;
revoke execute on function public.odds_admin_wallet_members() from public,anon,authenticated;
revoke execute on function public.odds_admin_add_credit(uuid,integer,text) from public,anon,authenticated;
revoke execute on function public.odds_admin_create_week(text,timestamptz,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function public.odds_my_wallet_details() to authenticated;
grant execute on function public.odds_my_wallet_history() to authenticated;
grant execute on function public.odds_admin_wallet_members() to authenticated;
grant execute on function public.odds_admin_add_credit(uuid,integer,text) to authenticated;
grant execute on function public.odds_admin_create_week(text,timestamptz,timestamptz,jsonb) to authenticated;
commit;

select proname as funktion,prosecdef as security_definer
from pg_proc where pronamespace='public'::regnamespace
and proname in ('odds_my_wallet','odds_my_wallet_details','odds_my_wallet_history',
'odds_admin_wallet_members','odds_admin_add_credit','odds_admin_create_week')
order by proname;
