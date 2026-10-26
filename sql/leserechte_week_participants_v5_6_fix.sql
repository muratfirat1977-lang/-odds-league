-- Nur bei: permission denied for table week_participants
-- In Supabase > SQL Editor ausfuehren. Keine Daten werden veraendert.
-- Bestehende RLS-Regeln bleiben unveraendert; kein Schreibrecht.
begin;
do $$
begin
  if not exists (
    select 1 from pg_class
    where oid = 'public.week_participants'::regclass and relrowsecurity
  ) then
    raise exception 'Abbruch: RLS fuer week_participants ist nicht aktiv.';
  end if;
  if not exists (
    select 1 from pg_policy
    where polrelid = 'public.week_participants'::regclass
      and polcmd in ('r','*')
  ) then
    raise exception 'Abbruch: Keine SELECT-RLS-Regel vorhanden. Erst Zugriffskonzept pruefen.';
  end if;
end;
$$;
grant usage on schema public to authenticated;
grant select on table public.week_participants to authenticated;
commit;
notify pgrst, 'reload schema';

select has_table_privilege('authenticated','public.week_participants','SELECT') as select_ok,
       relrowsecurity as rls_aktiv
from pg_class where oid = 'public.week_participants'::regclass;
