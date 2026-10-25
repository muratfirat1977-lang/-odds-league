-- Odds League V5.6 – Leserechte für Spielwochen wiederherstellen
-- Fehler: permission denied for table weeks
-- Keine Änderung an Guthaben, Tipps oder Spielergebnissen.
begin;

-- Sicherheit: Bevor Tabellen wieder direkt lesbar werden,
-- muss die zeilenweise Zugriffskontrolle (RLS) aktiv sein.
do $$
begin
  if exists (
    select 1
    from pg_class c
    where c.oid in ('public.weeks'::regclass,
                    'public.games'::regclass,
                    'public.tips'::regclass)
      and not c.relrowsecurity
  ) then
    raise exception 'Abbruch: RLS muss für weeks, games und tips aktiviert sein.';
  end if;
end;
$$;

grant usage on schema public to authenticated;
grant select on table public.weeks to authenticated;
grant select on table public.games to authenticated;
grant select on table public.tips to authenticated;

commit;
notify pgrst, 'reload schema';

-- Prüfen: Wochen, Spiele und Tipps lesbar; RLS weiterhin aktiv.
select
  c.relname as tabelle,
  has_table_privilege('authenticated',c.oid,'SELECT') as select_ok,
  c.relrowsecurity as rls_aktiv
from pg_class c
where c.oid in ('public.weeks'::regclass,
                'public.games'::regclass,
                'public.tips'::regclass)
order by c.relname;
