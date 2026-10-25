-- ODDS LEAGUE: Einladungen / geschuetzte Spielerverwaltung
-- Keine geheimen API-Schluessel in der Webseite verwenden.
-- Idempotent: kann im SQL Editor erneut ausgefuehrt werden.

begin;

-- Einladungen legen automatisch ein NOCH NICHT aktives Spielerprofil an.
create or replace function public.odds_league_profile_from_auth()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, role, active)
  values (
    new.id,
    left(coalesce(nullif(split_part(new.email,'@',1),''),'Neuer Spieler'),40),
    'player',
    false
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

do $$
begin
  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'auth.users'::regclass
      and tgname = 'odds_league_auth_user_insert'
      and not tgisinternal
  ) then
    create trigger odds_league_auth_user_insert
    after insert on auth.users
    for each row execute function public.odds_league_profile_from_auth();
  end if;
end;
$$;

-- Bereits bestehende eingeladene Benutzer ohne Profil nachtragen.
-- Bereits angelegte Profile (vor allem das Adminkonto) bleiben unberuehrt.
insert into public.profiles (id, display_name, role, active)
select
  u.id,
  left(coalesce(nullif(split_part(u.email,'@',1),''),'Neuer Spieler'),40),
  'player',
  false
from auth.users u
where not exists (
  select 1 from public.profiles p where p.id = u.id
)
on conflict (id) do nothing;

-- Minimale Mitgliederdaten nur fuer angemeldete aktive Admins.
create or replace function public.odds_admin_members(p_week_id bigint)
returns table (
  member_id uuid,
  member_name text,
  member_role text,
  member_active boolean,
  in_week boolean
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = (select auth.uid())
      and a.role = 'admin' and a.active = true
  ) then
    raise exception 'Nur Administratoren duerfen Mitglieder verwalten.';
  end if;

  return query
  select
    p.id,
    p.display_name,
    p.role,
    p.active,
    exists (
      select 1 from public.week_participants wp
      where wp.week_id = p_week_id and wp.user_id = p.id
    )
  from public.profiles p
  order by p.role desc, p.display_name, p.id;
end;
$$;

-- Admin darf Spielernamen, Aktivierung und Wochenzulassung verwalten,
-- aber niemals Rollen selbst vergeben oder andere Administratoren aendern.
create or replace function public.odds_admin_update_member(
  p_member_id uuid,
  p_display_name text,
  p_active boolean,
  p_week_id bigint,
  p_enrolled boolean
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text;
  v_current_enrolled boolean;
  v_settled boolean;
  v_first_kickoff timestamptz;
  v_week_ends timestamptz;
begin
  if not exists (
    select 1 from public.profiles a
    where a.id = (select auth.uid())
      and a.role = 'admin' and a.active = true
  ) then
    raise exception 'Keine Administratorberechtigung.';
  end if;

  if p_member_id is null or p_active is null or p_enrolled is null
     or p_display_name is null
     or char_length(btrim(p_display_name)) not between 2 and 40 then
    raise exception 'Ungueltige Mitgliedsdaten (Name: 2 bis 40 Zeichen).';
  end if;

  select p.role into v_role
  from public.profiles p
  where p.id = p_member_id
  for update;
  if not found then
    raise exception 'Spielerprofil nicht gefunden.';
  end if;
  if v_role <> 'player' then
    raise exception 'Administratoren koennen hier nicht veraendert werden.';
  end if;

  select w.settled, w.ends_at into v_settled, v_week_ends
  from public.weeks w where w.id = p_week_id;
  if not found then
    raise exception 'Spielwoche nicht gefunden.';
  end if;

  select exists (
    select 1 from public.week_participants wp
    where wp.week_id = p_week_id and wp.user_id = p_member_id
  ) into v_current_enrolled;

  if p_enrolled is distinct from v_current_enrolled then
    select min(g.kickoff) into v_first_kickoff
    from public.games g where g.week_id = p_week_id;

    if v_settled is distinct from false
       or now() >= coalesce(v_first_kickoff,v_week_ends) - interval '5 minutes'
    then
      raise exception 'Teilnehmerliste ist fuer diese Woche bereits gesperrt.';
    end if;

    if p_enrolled then
      if not p_active then
        raise exception 'Zuerst den Spieler aktivieren.';
      end if;
      insert into public.week_participants (week_id,user_id)
      values (p_week_id,p_member_id)
      on conflict do nothing;
    else
      if exists (
        select 1 from public.tips t
        join public.games g on g.id=t.game_id
        where t.user_id=p_member_id and g.week_id=p_week_id
      ) then
        raise exception 'Spieler mit Tipps kann nicht aus dieser Woche entfernt werden.';
      end if;
      delete from public.week_participants
      where week_id=p_week_id and user_id=p_member_id;
    end if;
  end if;

  update public.profiles
  set display_name = btrim(p_display_name), active = p_active
  where id = p_member_id;

  return 'Spieler gespeichert.';
end;
$$;

-- Nur eingeloggte Benutzer duerfen die RPCs aufrufen.
-- Die Funktionen selbst pruefen ZUSAETZLICH die Adminrolle.
revoke execute on function public.odds_league_profile_from_auth()
  from public, anon, authenticated;
revoke execute on function public.odds_admin_members(bigint)
  from public, anon, authenticated;
revoke execute on function public.odds_admin_update_member(uuid,text,boolean,bigint,boolean)
  from public, anon, authenticated;

grant execute on function public.odds_admin_members(bigint) to authenticated;
grant execute on function public.odds_admin_update_member(uuid,text,boolean,bigint,boolean)
  to authenticated;

commit;

-- Abschliessende pruefende Ausgabe:
select proname as funktion,prosecdef as security_definer
from pg_proc
where pronamespace='public'::regnamespace
and proname in (
 'odds_league_profile_from_auth',
 'odds_admin_members',
 'odds_admin_update_member'
)
order by proname;
