-- Wstaw e-mail ISTNIEJĄCEGO użytkownika Supabase Auth, następnie uruchom jako postgres.
-- UUID wyświetlony w wyniku wpisz w ustawieniach aplikacji. Uruchom raz dla zakładu.
do $$
declare
  admin_email text := 'ZMIEN_NA_EMAIL_ADMINISTRATORA';
  admin_id uuid;
  workspace uuid;
begin
  select id into admin_id from auth.users where lower(email) = lower(admin_email);
  if admin_id is null then raise exception 'Najpierw utwórz użytkownika Auth i wpisz jego e-mail.'; end if;
  insert into public.mes_workspaces(name) values ('Machines Pióro') returning id into workspace;
  insert into public.mes_memberships(workspace_id,user_id,role) values(workspace,admin_id,'admin');
  raise notice 'ID ZAKŁADU: %', workspace;
end;
$$;
-- Zwraca zakłady i ich administratorów, aby łatwo skopiować właściwe ID.
select w.id as workspace_id, w.name, u.email as administrator
from public.mes_workspaces w
join public.mes_memberships m on m.workspace_id=w.id and m.role='admin'
join auth.users u on u.id=m.user_id
order by w.created_at desc;
