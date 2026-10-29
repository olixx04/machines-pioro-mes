-- Machines Pióro MES · schema 1 · uruchom jako właściciel projektu w SQL Editor.
-- Tabele pozostają prywatne dla anonimowego klienta. Zapis wyłącznie przez RPC.
begin;
create schema if not exists mes_private;
revoke all on schema mes_private from public, anon;
grant usage on schema mes_private to authenticated;

create table if not exists public.mes_workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(name) between 1 and 160),
  created_at timestamptz not null default now()
);
create table if not exists public.mes_memberships (
  workspace_id uuid not null references public.mes_workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('admin', 'operator', 'viewer')),
  primary key (workspace_id, user_id)
);
create index if not exists mes_memberships_user_idx on public.mes_memberships(user_id);
create table if not exists public.mes_snapshots (
  workspace_id uuid primary key references public.mes_workspaces(id) on delete cascade,
  version bigint not null check (version >= 1),
  state jsonb not null check (jsonb_typeof(state) = 'object'),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
create table if not exists public.mes_audit (
  id bigint generated always as identity primary key,
  workspace_id uuid not null references public.mes_workspaces(id) on delete cascade,
  version bigint not null,
  actor_id uuid references auth.users(id) on delete set null,
  action text not null default 'snapshot_saved',
  created_at timestamptz not null default now(),
  unique (workspace_id, version)
);
create index if not exists mes_audit_workspace_time_idx on public.mes_audit(workspace_id, created_at desc);

alter table public.mes_workspaces enable row level security;
alter table public.mes_memberships enable row level security;
alter table public.mes_snapshots enable row level security;
alter table public.mes_audit enable row level security;
revoke all on public.mes_workspaces, public.mes_memberships, public.mes_snapshots, public.mes_audit from anon, authenticated;
revoke all on sequence public.mes_audit_id_seq from anon, authenticated;

-- Wyłącznie własna rola; brak rekursji zasad RLS i brak samodzielnego dołączania.
create or replace function mes_private.member_role(p_workspace_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select m.role from public.mes_memberships m
  where m.workspace_id = p_workspace_id and m.user_id = (select auth.uid());
$$;
revoke all on function mes_private.member_role(uuid) from public, anon, authenticated;
grant execute on function mes_private.member_role(uuid) to authenticated;
grant select on public.mes_workspaces, public.mes_memberships, public.mes_snapshots, public.mes_audit to authenticated;
drop policy if exists mes_workspaces_read on public.mes_workspaces;
create policy mes_workspaces_read on public.mes_workspaces for select to authenticated using (mes_private.member_role(id) is not null);
drop policy if exists mes_memberships_read on public.mes_memberships;
create policy mes_memberships_read on public.mes_memberships for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists mes_snapshots_read on public.mes_snapshots;
create policy mes_snapshots_read on public.mes_snapshots for select to authenticated using (mes_private.member_role(workspace_id) is not null);
drop policy if exists mes_audit_read on public.mes_audit;
create policy mes_audit_read on public.mes_audit for select to authenticated using (mes_private.member_role(workspace_id) is not null);

create or replace function mes_private.valid_number(p jsonb, k text, lo numeric, hi numeric, whole boolean default false)
returns boolean language plpgsql immutable set search_path = '' as $$
declare n numeric;
begin
  if jsonb_typeof(p -> k) is distinct from 'number' then return false; end if;
  n := (p ->> k)::numeric;
  return n >= lo and n <= hi and (not whole or n = trunc(n));
end; $$;
create or replace function mes_private.valid_text(p jsonb, k text, lo integer, hi integer)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(jsonb_typeof(p -> k) = 'string' and length(p ->> k) between lo and hi
    and (lo = 0 or length(regexp_replace(p ->> k, '[[:space:]]', '', 'g')) > 0)
    and (p ->> k) !~ E'[\\x01-\\x08\\x0B\\x0C\\x0E-\\x1F]', false);
$$;
create or replace function mes_private.valid_keys(p jsonb, allowed text[])
returns boolean language plpgsql immutable set search_path = '' as $$
begin
  if jsonb_typeof(p) is distinct from 'object' then return false; end if;
  return not exists(select 1 from jsonb_object_keys(p) k where not (k = any(allowed)));
end; $$;
create or replace function mes_private.valid_date(p jsonb, k text, day_only boolean default false)
returns boolean language plpgsql stable set search_path = '' as $$
declare value text; parsed timestamptz;
begin
  if not mes_private.valid_text(p,k,1,40) then return false; end if;
  value := p ->> k;
  if day_only then
    if value !~ '^\d{4}-\d{2}-\d{2}$' then return false; end if;
    return to_char(value::date,'YYYY-MM-DD') = value;
  end if;
  if value !~ '^\d{4}-\d{2}-\d{2}T' then return false; end if;
  parsed := value::timestamptz;
  return isfinite(parsed);
exception when invalid_datetime_format or datetime_field_overflow then return false;
end; $$;
create or replace function mes_private.valid_document(d jsonb)
returns boolean language plpgsql immutable set search_path = '' as $$
begin
  if not mes_private.valid_keys(d,array['kind','name','pages','data']) or not mes_private.valid_text(d,'name',1,200)
     or not mes_private.valid_number(d,'pages',1,500,true) then return false; end if;
  if d ->> 'kind' = 'demo' then return not (d ? 'data'); end if;
  return coalesce(d ->> 'kind' = 'pdf' and mes_private.valid_text(d,'data',8,4194304)
    and (d ->> 'data') ~ '^JVBERi0[A-Za-z0-9+/]*={0,2}$' and length(d ->> 'data') % 4 = 0, false);
end; $$;
create or replace function mes_private.valid_part_base(p jsonb, materials jsonb)
returns boolean language plpgsql immutable set search_path = '' as $$
begin
  if jsonb_typeof(p) is distinct from 'object'
    or not mes_private.valid_text(p,'code',1,100) or not mes_private.valid_text(p,'name',1,200)
    or not mes_private.valid_text(p,'materialId',1,100)
    or not mes_private.valid_number(p,'diameter',0,100000,false)
    or not mes_private.valid_number(p,'lengthMm',0,1000000,false)
    or not mes_private.valid_number(p,'qty',1,1000000,true)
    or not mes_private.valid_number(p,'page',1,500,true)
    or (p ->> 'source') is null or (p ->> 'source') not in ('saw','stock')
    or not exists (select 1 from jsonb_array_elements(materials) m where m ->> 'id' = p ->> 'materialId')
  then return false; end if;
  if p -> 'x' = 'null'::jsonb and p -> 'y' = 'null'::jsonb then return true; end if;
  return mes_private.valid_number(p,'x',0,1,false) and mes_private.valid_number(p,'y',0,1,false);
end; $$;

create or replace function mes_private.validate_state(s jsonb)
returns void language plpgsql set search_path = '' as $$
declare k text; a jsonb; item jsonb; sub jsonb; doc jsonb;
begin
  if s is null or not mes_private.valid_keys(s,array['schemaVersion','revision','updatedAt','orders','parts','materials','stock','templates','events'])
    or s -> 'schemaVersion' is distinct from '1'::jsonb
    or not mes_private.valid_number(s,'revision',0,9007199254740990,true)
    or not mes_private.valid_date(s,'updatedAt')
  then raise sqlstate 'PT400' using message = 'Nieprawidłowy nagłówek bazy.'; end if;
  if octet_length(s::text) > 2097152 then raise sqlstate 'PT413' using message = 'Limit migawki wynosi 2 MiB.'; end if;
  foreach k in array array['orders','parts','materials','stock','templates','events'] loop
    a := s -> k;
    if jsonb_typeof(a) is distinct from 'array' then raise sqlstate 'PT400' using message = 'Brak tablicy: ' || k; end if;
    if jsonb_array_length(a) > case k when 'parts' then 20000 when 'stock' then 10000 when 'events' then 300 when 'templates' then 500 else 1000 end
    then raise sqlstate 'PT400' using message = 'Przekroczono limit pozycji: ' || k; end if;
    if exists(select 1 from jsonb_array_elements(a) e where jsonb_typeof(e) is distinct from 'object' or not mes_private.valid_text(e,'id',1,100))
      or exists(select 1 from jsonb_array_elements(a) e group by e ->> 'id' having count(*) > 1)
    then raise sqlstate 'PT400' using message = 'Nieprawidłowe lub powielone identyfikatory: ' || k; end if;
  end loop;
  for item in select value from jsonb_array_elements(s -> 'materials') loop
    if not mes_private.valid_keys(item,array['id','name','grade','profile','diameter','stockMm','minMm','location','remnants'])
      or not mes_private.valid_text(item,'name',1,200) or not mes_private.valid_text(item,'grade',1,60)
      or not mes_private.valid_text(item,'profile',1,100) or not mes_private.valid_text(item,'location',1,150)
      or not mes_private.valid_number(item,'diameter',0,100000,false)
      or not mes_private.valid_number(item,'stockMm',0,1000000000000,false)
      or not mes_private.valid_number(item,'minMm',0,1000000000000,false)
      or jsonb_typeof(item -> 'remnants') is distinct from 'array'
    then raise sqlstate 'PT400' using message = 'Nieprawidłowy materiał.'; end if;
    if jsonb_array_length(item -> 'remnants') > 1000 then raise sqlstate 'PT400' using message = 'Zbyt wiele resztek.'; end if;
    for sub in select value from jsonb_array_elements(item -> 'remnants') loop
      if not mes_private.valid_keys(sub,array['id','lengthMm','qty'])
        or not mes_private.valid_text(sub,'id',1,100) or not mes_private.valid_number(sub,'lengthMm',0.001,1000000,false)
        or not mes_private.valid_number(sub,'qty',1,1000000,true) then raise sqlstate 'PT400' using message = 'Nieprawidłowa resztka.'; end if;
    end loop;
    if exists(select 1 from jsonb_array_elements(item -> 'remnants') e group by e ->> 'id' having count(*) > 1)
      then raise sqlstate 'PT400' using message = 'Powielone resztki.'; end if;
  end loop;
  for item in select value from jsonb_array_elements(s -> 'orders') loop
    if not mes_private.valid_keys(item,array['id','number','name','customer','dueDate','priority','createdAt','archived','document'])
      or not mes_private.valid_text(item,'name',1,200) or not mes_private.valid_text(item,'number',1,60)
      or not mes_private.valid_text(item,'customer',0,200) or not mes_private.valid_date(item,'dueDate',true)
      or not mes_private.valid_date(item,'createdAt') or jsonb_typeof(item -> 'archived') is distinct from 'boolean'
      or (item ->> 'priority') is null or (item ->> 'priority') not in ('normal','high')
      or not mes_private.valid_document(item -> 'document')
    then raise sqlstate 'PT400' using message = 'Nieprawidłowe zlecenie lub dokument.'; end if;
  end loop;
  for item in select value from jsonb_array_elements(s -> 'parts') loop
    if not mes_private.valid_keys(item,array['id','orderId','code','name','materialId','diameter','lengthMm','qty','page','x','y','source','cutQty','doneQty','status','minutes','problem','consumedMm'])
      or not mes_private.valid_part_base(item,s -> 'materials')
      or not mes_private.valid_text(item,'orderId',1,100)
      or not mes_private.valid_number(item,'cutQty',0,(item ->> 'qty')::numeric,true)
      or not mes_private.valid_number(item,'doneQty',0,(item ->> 'cutQty')::numeric,true)
      or not mes_private.valid_number(item,'minutes',0,10000000,false)
      or not mes_private.valid_number(item,'consumedMm',0,1000000000000,false)
      or not mes_private.valid_text(item,'problem',0,1000)
      or (item ->> 'status') is null or (item ->> 'status') not in ('queued','cutting','cut','turning','done','problem')
    then raise sqlstate 'PT400' using message = 'Nieprawidłowy detal.'; end if;
    select o -> 'document' into doc from jsonb_array_elements(s -> 'orders') o where o ->> 'id' = item ->> 'orderId';
    if doc is null or (item ->> 'page')::integer > (doc ->> 'pages')::integer
      or ((item ->> 'status' = 'done') <> ((item ->> 'doneQty')::numeric = (item ->> 'qty')::numeric))
      or (item ->> 'status' = 'cut' and (item ->> 'cutQty')::numeric <> (item ->> 'qty')::numeric)
      or (item ->> 'status' = 'turning' and (item ->> 'cutQty')::numeric <= (item ->> 'doneQty')::numeric)
    then raise sqlstate 'PT400' using message = 'Nieprawidłowa relacja, strona lub status detalu.'; end if;
  end loop;
  for item in select value from jsonb_array_elements(s -> 'stock') loop
    if not mes_private.valid_keys(item,array['id','code','name','qty','location'])
      or not mes_private.valid_text(item,'code',1,100) or not mes_private.valid_text(item,'name',1,200)
      or not mes_private.valid_text(item,'location',1,150) or not mes_private.valid_number(item,'qty',0,1000000,true)
    then raise sqlstate 'PT400' using message = 'Nieprawidłowa pozycja magazynu.'; end if;
  end loop;
  for item in select value from jsonb_array_elements(s -> 'templates') loop
    if not mes_private.valid_keys(item,array['id','name','document','parts'])
      or not mes_private.valid_text(item,'name',1,200) or not mes_private.valid_document(item -> 'document')
      or jsonb_typeof(item -> 'parts') is distinct from 'array'
    then raise sqlstate 'PT400' using message = 'Nieprawidłowy szablon.'; end if;
    if jsonb_array_length(item -> 'parts') > 1000 then raise sqlstate 'PT400' using message = 'Zbyt wiele detali szablonu.'; end if;
    for sub in select value from jsonb_array_elements(item -> 'parts') loop
      if not mes_private.valid_keys(sub,array['code','name','materialId','diameter','lengthMm','qty','page','x','y','source'])
        or not mes_private.valid_part_base(sub,s -> 'materials') or (sub ->> 'page')::integer > (item -> 'document' ->> 'pages')::integer
      then raise sqlstate 'PT400' using message = 'Nieprawidłowy detal szablonu.'; end if;
    end loop;
  end loop;
  for item in select value from jsonb_array_elements(s -> 'events') loop
    if not mes_private.valid_keys(item,array['id','at','label','detail'])
      or not mes_private.valid_date(item,'at') or not mes_private.valid_text(item,'label',1,500)
      or (item ? 'detail' and not mes_private.valid_text(item,'detail',0,1000))
    then raise sqlstate 'PT400' using message = 'Nieprawidłowy wpis historii.'; end if;
  end loop;
exception when invalid_text_representation or numeric_value_out_of_range then
  raise sqlstate 'PT400' using message = 'Nieprawidłowy format liczby.';
end; $$;

create or replace function mes_private.load_state(p_workspace_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare member text; snap public.mes_snapshots%rowtype;
begin
  member := mes_private.member_role(p_workspace_id);
  if auth.uid() is null or member is null then raise sqlstate 'PT403' using message = 'Brak członkostwa w zakładzie.'; end if;
  select * into snap from public.mes_snapshots where workspace_id = p_workspace_id;
  return jsonb_build_object('state', snap.state, 'version', coalesce(snap.version,0), 'updatedAt', snap.updated_at, 'role', member);
end; $$;
create or replace function mes_private.save_state(p_workspace_id uuid, p_expected_version bigint, p_state jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare member text; current_version bigint; snap public.mes_snapshots%rowtype; actor uuid;
begin
  actor := auth.uid();
  member := mes_private.member_role(p_workspace_id);
  if actor is null or member is null or member not in ('admin','operator') then raise sqlstate 'PT403' using message = 'Brak prawa zapisu.'; end if;
  if p_expected_version is null or p_expected_version < 0 then raise sqlstate 'PT400' using message = 'Nieprawidłowa oczekiwana wersja.'; end if;
  perform mes_private.validate_state(p_state);
  -- Blokada rodzica zabezpiecza także pierwszy równoległy zapis (wersja 0).
  perform 1 from public.mes_workspaces where id = p_workspace_id for update;
  if not found then raise sqlstate 'PT403' using message = 'Zakład nie istnieje.'; end if;
  -- Ponowna autoryzacja po oczekiwaniu na blokadę.
  member := mes_private.member_role(p_workspace_id);
  if member is null or member not in ('admin','operator') then raise sqlstate 'PT403' using message = 'Brak prawa zapisu.'; end if;
  select version into current_version from public.mes_snapshots where workspace_id = p_workspace_id;
  current_version := coalesce(current_version,0);
  if current_version <> p_expected_version then raise sqlstate 'PT409' using message = 'Nowsza wersja istnieje. Pobierz ponownie.'; end if;
  insert into public.mes_snapshots(workspace_id,version,state,updated_by,updated_at)
  values(p_workspace_id,current_version+1,p_state,actor,now())
  on conflict(workspace_id) do update set version=excluded.version,state=excluded.state,updated_by=excluded.updated_by,updated_at=excluded.updated_at
  returning * into snap;
  insert into public.mes_audit(workspace_id,version,actor_id) values(p_workspace_id,snap.version,actor);
  return jsonb_build_object('state',snap.state,'version',snap.version,'updatedAt',snap.updated_at,'role',member);
end; $$;

-- Publiczne RPC są invoker; ograniczone funkcje zapisu znajdują się w prywatnym schemacie.
create or replace function public.mes_load_state(p_workspace_id uuid)
returns jsonb language sql security invoker set search_path = '' as $$
  select mes_private.load_state(p_workspace_id);
$$;
create or replace function public.mes_save_state(p_workspace_id uuid, p_expected_version bigint, p_state jsonb)
returns jsonb language sql security invoker set search_path = '' as $$
  select mes_private.save_state(p_workspace_id,p_expected_version,p_state);
$$;
revoke all on all functions in schema mes_private from public, anon, authenticated;
grant execute on function mes_private.member_role(uuid), mes_private.load_state(uuid), mes_private.save_state(uuid,bigint,jsonb) to authenticated;
revoke all on function public.mes_load_state(uuid), public.mes_save_state(uuid,bigint,jsonb) from public, anon, authenticated;
grant execute on function public.mes_load_state(uuid), public.mes_save_state(uuid,bigint,jsonb) to authenticated;
commit;
