-- Uruchom PO schema.sql w SQL Editor jako postgres, wyłącznie w projekcie testowym.
-- Wszystkie fixture są wycofywane na końcu. Wymaga dostępnego rozszerzenia pgTAP.
begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(23);

insert into auth.users(id,email) values
 ('a1000000-0000-4000-8000-000000000001','mes-test-admin@example.invalid'),
 ('a1000000-0000-4000-8000-000000000002','mes-test-viewer@example.invalid'),
 ('a1000000-0000-4000-8000-000000000003','mes-test-outsider@example.invalid');
insert into public.mes_workspaces(id,name) values ('b1000000-0000-4000-8000-000000000001','MES test');
insert into public.mes_memberships(workspace_id,user_id,role) values
 ('b1000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','admin'),
 ('b1000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000002','viewer');

select extensions.is((select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('mes_workspaces','mes_memberships','mes_snapshots','mes_audit') and c.relrowsecurity),4::bigint,'RLS włączone na wszystkich tabelach');
select extensions.ok(not has_table_privilege('anon','public.mes_snapshots','SELECT'),'anon nie czyta migawki');
select extensions.ok(not has_table_privilege('authenticated','public.mes_snapshots','INSERT'),'brak bezpośredniego INSERT migawki');
select extensions.ok(not has_table_privilege('authenticated','public.mes_memberships','INSERT'),'brak samodzielnego członkostwa');
select extensions.ok(not has_table_privilege('authenticated','public.mes_audit','UPDATE'),'klient nie zmienia audytu');
select extensions.ok(not has_function_privilege('authenticated','mes_private.validate_state(jsonb)','EXECUTE'),'wewnętrzna walidacja nie jest publiczna');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a1000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select extensions.is((public.mes_load_state('b1000000-0000-4000-8000-000000000001')->>'version')::bigint,0::bigint,'pierwszy odczyt ma wersję zero');
select extensions.is(public.mes_load_state('b1000000-0000-4000-8000-000000000001')->'state','null'::jsonb,'pierwszy odczyt nie zawiera danych');
select extensions.is((public.mes_save_state('b1000000-0000-4000-8000-000000000001',0,'{"schemaVersion":1,"revision":0,"updatedAt":"2026-10-28T10:00:00.000Z","orders":[],"parts":[],"materials":[],"stock":[],"templates":[],"events":[]}'::jsonb)->>'version')::bigint,1::bigint,'pierwszy zapis zwiększa wersję');
select extensions.throws_ok($$select public.mes_save_state('b1000000-0000-4000-8000-000000000001',0,'{"schemaVersion":1,"revision":0,"updatedAt":"2026-10-28T10:00:00.000Z","orders":[],"parts":[],"materials":[],"stock":[],"templates":[],"events":[]}'::jsonb)$$,'PT409',null,'stara wersja zwraca konflikt');
select extensions.is((public.mes_load_state('b1000000-0000-4000-8000-000000000001')->>'version')::bigint,1::bigint,'konflikt nie zmienia wersji');
select extensions.throws_ok($$select public.mes_save_state('b1000000-0000-4000-8000-000000000001',1,'{"schemaVersion":1,"revision":-1,"updatedAt":"2026-10-28T10:00:00.000Z","orders":[],"parts":[],"materials":[],"stock":[],"templates":[],"events":[]}'::jsonb)$$,'PT400',null,'ujemne wartości są odrzucane');
select extensions.throws_ok($$select public.mes_save_state('b1000000-0000-4000-8000-000000000001',1,'{"schemaVersion":1,"revision":0,"updatedAt":"2026-10-28T10:00:00.000Z","orders":[],"parts":[],"materials":[],"stock":[],"templates":[],"events":[],"extra":"invalid"}'::jsonb)$$,'PT400',null,'nieznane pola są odrzucane');
select extensions.throws_ok($$select public.mes_save_state('b1000000-0000-4000-8000-000000000001',1,'{"schemaVersion":"1","revision":0,"updatedAt":"nie-data","orders":[],"parts":[],"materials":[],"stock":[],"templates":[],"events":[]}'::jsonb)$$,'PT400',null,'typ schematu i daty są sprawdzane');
select extensions.is((select count(*) from public.mes_audit where workspace_id='b1000000-0000-4000-8000-000000000001'),1::bigint,'jeden zatwierdzony zapis daje jeden wpis audytu');

select set_config('request.jwt.claims','{"sub":"a1000000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select extensions.is(public.mes_load_state('b1000000-0000-4000-8000-000000000001')->>'role','viewer','viewer może odczytać');
select extensions.throws_ok($$select public.mes_save_state('b1000000-0000-4000-8000-000000000001',1,'{}'::jsonb)$$,'PT403',null,'viewer nie zapisuje');
select extensions.throws_ok($$update public.mes_memberships set role='admin' where user_id='a1000000-0000-4000-8000-000000000002'$$,'42501',null,'viewer nie podnosi swojej roli');

select set_config('request.jwt.claims','{"sub":"a1000000-0000-4000-8000-000000000003","role":"authenticated"}',true);
select extensions.throws_ok($$select public.mes_load_state('b1000000-0000-4000-8000-000000000001')$$,'PT403',null,'użytkownik spoza zakładu nie czyta przez RPC');
select extensions.is((select count(*) from public.mes_snapshots),0::bigint,'RLS ukrywa migawki przed obcym');
select extensions.throws_ok($$insert into public.mes_memberships(workspace_id,user_id,role) values('b1000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000003','admin')$$,'42501',null,'obcy nie dodaje siebie do zakładu');

set local role anon;
select set_config('request.jwt.claims','{"role":"anon"}',true);
select extensions.throws_ok($$select public.mes_load_state('b1000000-0000-4000-8000-000000000001')$$,'42501',null,'anon nie wywołuje RPC');
select extensions.throws_ok($$select * from public.mes_snapshots$$,'42501',null,'anon nie czyta tabeli');
reset role;
select * from extensions.finish();
rollback;
