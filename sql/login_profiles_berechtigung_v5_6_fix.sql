-- Odds League V5.6 – Login-Reparatur: "permission denied for table profiles"
-- Dieses Skript aendert KEINE Benutzer, Tipps, Einsaetze oder Guthaben.
-- Es hebt KEINE Row-Level-Security auf und erteilt KEINEN Schreibzugriff.
begin;
grant usage on schema public to authenticated;
grant select on table public.profiles to authenticated;
commit;

notify pgrst, 'reload schema';

-- Erwartetes Ergebnis: profiles_select_ok = true
select
  has_table_privilege('authenticated','public.profiles','SELECT') as profiles_select_ok,
  (select relrowsecurity from pg_class where oid='public.profiles'::regclass)
    as rls_still_enabled;
