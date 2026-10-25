-- Odds League V5.6 – Guthaben korrigieren, ohne alte Buchungen zu loeschen.
-- Erst NACH guthaben_und_neue_woche_v5_5.sql ausfuehren.
-- KEINE Startguthaben oder alten Aufladungen erneut buchen.
begin;

-- Buchungstyp fuer nachvollziehbare Admin-Korrekturen freigeben.
alter table public.odds_wallet_entries
  drop constraint if exists odds_wallet_entries_kind_check;
alter table public.odds_wallet_entries
  add constraint odds_wallet_entries_kind_check
  check (kind in (
    'legacy_stake','legacy_prize','opening_stake','topup',
    'stake','stake_refund','prize','correction'
  ));

-- Auch bisherige Aufladebestaetigung auf exakt zwei Nachkommastellen formatieren.
-- Signatur bleibt gleich; Kontostaende und Buchungsdaten bleiben unveraendert.
create or replace function public.odds_admin_add_credit(
  p_member_id uuid, p_amount_cents integer, p_reason text
)
returns text
language plpgsql security definer set search_path=''
as $$
declare v_name text;
begin
  if not exists (
    select 1 from public.profiles p
    where p.id=(select auth.uid()) and p.role='admin' and p.active=true
  ) then
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
  if not found then raise exception 'Mitglied nicht gefunden.'; end if;
  insert into public.odds_wallet_accounts(user_id,balance_cents)
    values(p_member_id,0) on conflict(user_id) do nothing;
  update public.odds_wallet_accounts
    set balance_cents=balance_cents+p_amount_cents,updated_at=now()
    where user_id=p_member_id;
  insert into public.odds_wallet_entries
    (user_id,kind,amount_cents,reason,changed_by)
    values(p_member_id,'topup',p_amount_cents,btrim(p_reason),(select auth.uid()));
  return 'Guthaben fuer '||v_name||' um '||
    (p_amount_cents/100)::text||','||lpad((p_amount_cents%100)::text,2,'0')||
    ' EUR aufgeladen.';
end;
$$;

-- Negativer Korrekturbetrag, z.B. -4500 Cent wenn 50 statt 5 EUR gebucht wurden.
-- Jede Korrektur ist eine NEUE Buchung. Historische Eintraege bleiben unveraendert.
-- Der Request-Key verhindert Doppelkorrigieren beim erneuten Senden derselben Aktion.
create or replace function public.odds_admin_adjust_credit(
  p_member_id uuid,
  p_amount_cents integer,
  p_reason text,
  p_request_id uuid
)
returns text
language plpgsql security definer set search_path=''
as $$
declare
  v_name text;
  v_old bigint;
  v_new bigint;
  v_key text;
  v_record record;
begin
  if not exists (
    select 1 from public.profiles p
    where p.id=(select auth.uid()) and p.role='admin' and p.active=true
  ) then
    raise exception 'Nur der Administrator darf Korrekturbuchungen erfassen.';
  end if;
  if p_member_id is null or p_request_id is null
     or p_amount_cents is null or p_amount_cents > -1
     or p_amount_cents < -100000 then
    raise exception 'Bitte einen Korrekturabzug zwischen 0,01 und 1000,00 EUR eingeben.';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 8 and 160 then
    raise exception 'Die Korrektur benoetigt eine Begruendung von 8 bis 160 Zeichen.';
  end if;
  select p.display_name into v_name from public.profiles p
    where p.id=p_member_id for update;
  if not found then raise exception 'Mitglied nicht gefunden.'; end if;
  insert into public.odds_wallet_accounts(user_id,balance_cents)
    values(p_member_id,0) on conflict(user_id) do nothing;
  select a.balance_cents into v_old from public.odds_wallet_accounts a
    where a.user_id=p_member_id for update;
  v_key := 'admin-correction:'||p_request_id::text;

  select e.user_id,e.amount_cents,e.reason into v_record
  from public.odds_wallet_entries e where e.event_key=v_key;
  if found then
    if v_record.user_id<>p_member_id or v_record.amount_cents<>p_amount_cents
       or v_record.reason<>btrim(p_reason) then
      raise exception 'Diese Buchungskennung wurde bereits fuer andere Daten verwendet.';
    end if;
    return 'Diese Korrektur wurde bereits gebucht. Kein erneuter Abzug.';
  end if;

  v_new := v_old + p_amount_cents;
  update public.odds_wallet_accounts
    set balance_cents=v_new,updated_at=now()
    where user_id=p_member_id;
  insert into public.odds_wallet_entries
    (user_id,kind,amount_cents,reason,changed_by,event_key)
  values
    (p_member_id,'correction',p_amount_cents,btrim(p_reason),
      (select auth.uid()),v_key);

  return 'Korrektur gespeichert: '||v_name||'. Neuer Kontostand: '||
    v_new::text||' Cent.';
end;
$$;

-- Nur aktive Admins duerfen die letzten Aufladungen/Korrekturen ALLER Spieler sehen.
create or replace function public.odds_admin_credit_history(p_limit integer)
returns table (
  booked_at timestamptz,
  player_name text,
  kind text,
  amount_cents bigint,
  reason text,
  admin_name text
)
language plpgsql security definer set search_path=''
as $$
begin
  if not exists (
    select 1 from public.profiles p
    where p.id=(select auth.uid()) and p.role='admin' and p.active=true
  ) then
    raise exception 'Nur der Administrator darf Buchungen einsehen.';
  end if;
  return query
    select e.created_at, p.display_name::text, e.kind,
           e.amount_cents, e.reason, a.display_name::text
    from public.odds_wallet_entries e
    join public.profiles p on p.id=e.user_id
    left join public.profiles a on a.id=e.changed_by
    where e.kind in ('topup','correction')
    order by e.created_at desc,e.id desc
    limit greatest(1,least(coalesce(p_limit,30),100));
end;
$$;

revoke execute on function public.odds_admin_adjust_credit(uuid,integer,text,uuid)
  from public, anon, authenticated;
revoke execute on function public.odds_admin_credit_history(integer)
  from public, anon, authenticated;
grant execute on function public.odds_admin_adjust_credit(uuid,integer,text,uuid)
  to authenticated;
grant execute on function public.odds_admin_credit_history(integer)
  to authenticated;
commit;

select proname as funktion,prosecdef as security_definer
from pg_proc
where pronamespace='public'::regnamespace
  and proname in ('odds_admin_adjust_credit','odds_admin_credit_history','odds_admin_add_credit')
order by proname;
