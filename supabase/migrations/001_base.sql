-- DNBAR - estrutura base (etapa 1)
create extension if not exists pgcrypto with schema extensions;

create table public.establishments(
  id uuid primary key default gen_random_uuid(),
  name text not null,
  service_fee_pct numeric(5,2) not null default 10,
  kitchen_enabled boolean not null default false,
  order_seq integer not null default 0,
  created_at timestamptz not null default now()
);

create table public.members(
  user_id uuid primary key references auth.users(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  role text not null check (role in ('owner','device')),
  created_at timestamptz not null default now()
);

create table public.staff(
  id uuid primary key default gen_random_uuid(),
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  name text not null,
  role text not null check (role in ('garcom','gerente','cozinha','bar','caixa')),
  role_label text not null,
  photo_url text,
  portrait_url text,
  active boolean not null default true,
  sort int not null default 0,
  created_at timestamptz not null default now()
);
create index on public.staff(establishment_id);

create table public.staff_secrets(
  staff_id uuid primary key references public.staff(id) on delete cascade,
  pin_hash text not null,
  failed_attempts int not null default 0,
  locked_until timestamptz
);

create table public.staff_sessions(
  token uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id) on delete cascade,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '14 hours',
  revoked_at timestamptz
);
create index on public.staff_sessions(staff_id);

create table public.dining_tables(
  id uuid primary key default gen_random_uuid(),
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  label text not null,
  area text not null default 'Salão',
  sort int not null default 0,
  active boolean not null default true,
  unique(establishment_id, label)
);

create table public.categories(
  id uuid primary key default gen_random_uuid(),
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  slug text not null,
  name text not null,
  hue text,
  area text not null check (area in ('cozinha','bar')),
  sort int not null default 0,
  active boolean not null default true,
  unique(establishment_id, slug)
);

create table public.products(
  id uuid primary key default gen_random_uuid(),
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  category_id uuid not null references public.categories(id) on delete restrict,
  number int not null,
  name text not null,
  image_url text,
  icon text,
  price_cents int check (price_cents >= 0),
  sizes jsonb,
  available boolean not null default true,
  active boolean not null default true,
  sort int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(establishment_id, number)
);
create index on public.products(category_id);

create table public.table_sessions(
  id uuid primary key default gen_random_uuid(),
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  table_id uuid not null references public.dining_tables(id),
  waiter_id uuid not null references public.staff(id),
  people int not null default 2 check (people between 1 and 99),
  status text not null default 'open' check (status in ('open','closed')),
  flag text check (flag in ('chamou','conta','caixa')),
  flag_at timestamptz,
  opened_at timestamptz not null default now(),
  closed_at timestamptz
);
create unique index one_open_session_per_table on public.table_sessions(table_id) where status = 'open';
create index on public.table_sessions(establishment_id, status);
create index on public.table_sessions(waiter_id);

create table public.orders(
  id uuid primary key default gen_random_uuid(),
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  session_id uuid not null references public.table_sessions(id),
  number int not null,
  idempotency_key uuid not null,
  created_by uuid not null references public.staff(id),
  created_at timestamptz not null default now(),
  unique(establishment_id, idempotency_key)
);
create index on public.orders(session_id);
create index on public.orders(created_by);

create table public.order_items(
  id uuid primary key default gen_random_uuid(),
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  order_id uuid not null references public.orders(id),
  session_id uuid not null references public.table_sessions(id),
  product_id uuid not null references public.products(id),
  size_label text,
  name_snapshot text not null,
  unit_price_cents int not null,
  qty int not null check (qty between 1 and 99),
  note text,
  area text not null check (area in ('cozinha','bar')),
  status text not null default 'preparo' check (status in ('preparo','pronto','entregue','cancelado')),
  ready_at timestamptz,
  delivered_at timestamptz,
  delivered_by uuid references public.staff(id),
  cancelled_at timestamptz,
  cancelled_by uuid references public.staff(id),
  cancel_reason text,
  created_at timestamptz not null default now()
);
create index on public.order_items(session_id);
create index on public.order_items(order_id);
create index on public.order_items(product_id);
create index on public.order_items(delivered_by);
create index on public.order_items(cancelled_by);
create index on public.order_items(establishment_id, status);

-- linha do tempo + auditoria (nunca apagar)
create table public.session_events(
  id bigint generated always as identity primary key,
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  session_id uuid references public.table_sessions(id),
  staff_id uuid references public.staff(id),
  type text not null,
  message text not null,
  meta jsonb,
  created_at timestamptz not null default now()
);
create index on public.session_events(session_id);
create index on public.session_events(staff_id);
create index on public.session_events(establishment_id, created_at);

-- ================= RLS =================
create or replace function public.current_establishment_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select establishment_id from public.members where user_id = (select auth.uid())
$$;

alter table public.establishments enable row level security;
alter table public.members enable row level security;
alter table public.staff enable row level security;
alter table public.staff_secrets enable row level security;
alter table public.staff_sessions enable row level security;
alter table public.dining_tables enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.table_sessions enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.session_events enable row level security;

-- leitura: só dados do próprio bar. escrita: só pelas funções abaixo.
create policy "ler meu bar" on public.establishments for select to authenticated using (id = (select public.current_establishment_id()));
create policy "ler meu vinculo" on public.members for select to authenticated using (user_id = (select auth.uid()));
create policy "ler equipe" on public.staff for select to authenticated using (establishment_id = (select public.current_establishment_id()));
create policy "ler mesas" on public.dining_tables for select to authenticated using (establishment_id = (select public.current_establishment_id()));
create policy "ler categorias" on public.categories for select to authenticated using (establishment_id = (select public.current_establishment_id()));
create policy "ler produtos" on public.products for select to authenticated using (establishment_id = (select public.current_establishment_id()));
create policy "ler sessoes" on public.table_sessions for select to authenticated using (establishment_id = (select public.current_establishment_id()));
create policy "ler pedidos" on public.orders for select to authenticated using (establishment_id = (select public.current_establishment_id()));
create policy "ler itens" on public.order_items for select to authenticated using (establishment_id = (select public.current_establishment_id()));
create policy "ler eventos" on public.session_events for select to authenticated using (establishment_id = (select public.current_establishment_id()));
-- staff_secrets e staff_sessions: sem política = ninguém lê pela API.

-- ================= FUNÇÕES =================
create or replace function public._staff_from_token(p_token uuid) returns public.staff
language plpgsql security definer set search_path = '' as $$
declare s public.staff;
begin
  select st.* into s from public.staff_sessions ss join public.staff st on st.id = ss.staff_id
   where ss.token = p_token and ss.revoked_at is null and ss.expires_at > now() and st.active
     and ss.establishment_id = public.current_establishment_id();
  if not found then raise exception 'SESSAO_EXPIRADA'; end if;
  return s;
end $$;

create or replace function public._event(p_est uuid, p_session uuid, p_staff uuid, p_type text, p_msg text, p_meta jsonb default null) returns void
language sql security definer set search_path = '' as $$
  insert into public.session_events(establishment_id, session_id, staff_id, type, message, meta)
  values (p_est, p_session, p_staff, p_type, p_msg, p_meta)
$$;

-- login por foto + PIN. 5 erros = bloqueio de 5 minutos.
create or replace function public.staff_login(p_staff_id uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_est uuid := public.current_establishment_id(); v_staff public.staff; v_sec public.staff_secrets; v_tok uuid;
begin
  if v_est is null then return jsonb_build_object('ok',false,'error','APARELHO_NAO_AUTORIZADO'); end if;
  select * into v_staff from public.staff where id = p_staff_id and establishment_id = v_est and active;
  if not found then return jsonb_build_object('ok',false,'error','PIN_INVALIDO'); end if;
  select * into v_sec from public.staff_secrets where staff_id = p_staff_id for update;
  if not found then return jsonb_build_object('ok',false,'error','PIN_INVALIDO'); end if;
  if v_sec.locked_until is not null and v_sec.locked_until > now() then
    return jsonb_build_object('ok',false,'error','BLOQUEADO','until',v_sec.locked_until);
  end if;
  if p_pin is null or v_sec.pin_hash <> extensions.crypt(p_pin, v_sec.pin_hash) then
    update public.staff_secrets
       set failed_attempts = case when failed_attempts + 1 >= 5 then 0 else failed_attempts + 1 end,
           locked_until   = case when failed_attempts + 1 >= 5 then now() + interval '5 minutes' else null end
     where staff_id = p_staff_id;
    perform public._event(v_est, null, p_staff_id, 'login_falhou', v_staff.name || ' errou o PIN');
    return jsonb_build_object('ok',false,'error', case when v_sec.failed_attempts + 1 >= 5 then 'BLOQUEADO' else 'PIN_INVALIDO' end,
                              'left', greatest(0, 4 - v_sec.failed_attempts));
  end if;
  update public.staff_secrets set failed_attempts = 0, locked_until = null where staff_id = p_staff_id;
  insert into public.staff_sessions(staff_id, establishment_id) values (p_staff_id, v_est) returning token into v_tok;
  perform public._event(v_est, null, p_staff_id, 'login', v_staff.name || ' entrou');
  return jsonb_build_object('ok',true,'token',v_tok);
end $$;

create or replace function public.staff_logout(p_token uuid) returns void
language sql security definer set search_path = '' as $$
  update public.staff_sessions set revoked_at = now()
   where token = p_token and establishment_id = public.current_establishment_id() and revoked_at is null
$$;

create or replace function public.open_table(p_token uuid, p_table_id uuid, p_people int) returns uuid
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_from_token(p_token); v_label text; v_id uuid;
begin
  select label into v_label from public.dining_tables where id = p_table_id and establishment_id = s.establishment_id and active;
  if not found then raise exception 'MESA_INVALIDA'; end if;
  begin
    insert into public.table_sessions(establishment_id, table_id, waiter_id, people)
    values (s.establishment_id, p_table_id, s.id, greatest(1, least(99, coalesce(p_people, 2)))) returning id into v_id;
  exception when unique_violation then raise exception 'MESA_OCUPADA';
  end;
  perform public._event(s.establishment_id, v_id, s.id, 'mesa_aberta', s.name || ' abriu a mesa');
  return v_id;
end $$;

-- pedido: preço sempre do servidor, chave de idempotência evita duplicar
create or replace function public.create_order(p_token uuid, p_session_id uuid, p_key uuid, p_items jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s public.staff := public._staff_from_token(p_token);
  v_sess public.table_sessions; v_no int; v_oid uuid; it jsonb; p public.products; v_area text;
  v_price int; v_name text; v_size text; v_qty int; v_k int := 0; v_b int := 0; v_sum text;
begin
  select o.number into v_no from public.orders o where o.establishment_id = s.establishment_id and o.idempotency_key = p_key;
  if found then return jsonb_build_object('number', v_no, 'duplicate', true); end if;

  select * into v_sess from public.table_sessions where id = p_session_id and establishment_id = s.establishment_id and status = 'open' for update;
  if not found then raise exception 'MESA_FECHADA'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 50 then
    raise exception 'PEDIDO_VAZIO';
  end if;

  update public.establishments set order_seq = order_seq + 1 where id = s.establishment_id returning order_seq into v_no;
  insert into public.orders(establishment_id, session_id, number, idempotency_key, created_by)
  values (s.establishment_id, p_session_id, v_no, p_key, s.id)
  on conflict (establishment_id, idempotency_key) do nothing returning id into v_oid;
  if v_oid is null then
    select o.number into v_no from public.orders o where o.establishment_id = s.establishment_id and o.idempotency_key = p_key;
    return jsonb_build_object('number', v_no, 'duplicate', true);
  end if;

  for it in select * from jsonb_array_elements(p_items) loop
    select * into p from public.products where id = (it->>'product_id')::uuid and establishment_id = s.establishment_id and active;
    if not found then raise exception 'PRODUTO_INVALIDO'; end if;
    if not p.available then raise exception 'PRODUTO_ESGOTADO:%', p.name; end if;
    select c.area into v_area from public.categories c where c.id = p.category_id;
    v_size := nullif(it->>'size','');
    if p.sizes is not null and jsonb_array_length(p.sizes) > 0 then
      select (e->>'v')::int into v_price from jsonb_array_elements(p.sizes) e where e->>'l' = v_size;
      if v_price is null then raise exception 'TAMANHO_INVALIDO:%', p.name; end if;
      v_name := p.name || ' (' || lower(v_size) || ')';
    else
      v_price := p.price_cents; v_size := null; v_name := p.name;
      if v_price is null then raise exception 'SEM_PRECO:%', p.name; end if;
    end if;
    v_qty := (it->>'qty')::int;
    if v_qty is null or v_qty < 1 or v_qty > 99 then raise exception 'QUANTIDADE_INVALIDA'; end if;
    insert into public.order_items(establishment_id, order_id, session_id, product_id, size_label, name_snapshot, unit_price_cents, qty, note, area)
    values (s.establishment_id, v_oid, p_session_id, p.id, v_size, v_name, v_price, v_qty, left(nullif(trim(it->>'note'),''), 200), v_area);
    if v_area = 'bar' then v_b := v_b + v_qty; else v_k := v_k + v_qty; end if;
    v_sum := coalesce(v_sum || ', ', '') || v_qty || ' ' || v_name;
  end loop;

  perform public._event(s.establishment_id, p_session_id, s.id, 'pedido', s.name || ' lançou pedido #' || v_no || ': ' || v_sum, jsonb_build_object('order_id', v_oid));
  return jsonb_build_object('number', v_no, 'cozinha', v_k, 'bar', v_b, 'duplicate', false);
end $$;

-- garçom marca entregue (sem tela de cozinha ligada, entrega também o que está em preparo)
create or replace function public.deliver_ready(p_token uuid, p_session_id uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_from_token(p_token); v_kitchen boolean; v_n int;
begin
  select kitchen_enabled into v_kitchen from public.establishments where id = s.establishment_id;
  update public.order_items set status = 'entregue', delivered_at = now(), delivered_by = s.id
   where session_id = p_session_id and establishment_id = s.establishment_id
     and (status = 'pronto' or (status = 'preparo' and not v_kitchen));
  get diagnostics v_n = row_count;
  if v_n > 0 then perform public._event(s.establishment_id, p_session_id, s.id, 'entrega', s.name || ' entregou ' || v_n || case when v_n > 1 then ' itens' else ' item' end); end if;
  return v_n;
end $$;

create or replace function public.ack_call(p_token uuid, p_session_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_from_token(p_token);
begin
  update public.table_sessions set flag = null, flag_at = null where id = p_session_id and establishment_id = s.establishment_id and flag = 'chamou';
  if found then perform public._event(s.establishment_id, p_session_id, s.id, 'chamado', s.name || ' atendeu o chamado'); end if;
end $$;

create or replace function public.send_to_cashier(p_token uuid, p_session_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_from_token(p_token);
begin
  update public.table_sessions set flag = 'caixa', flag_at = now() where id = p_session_id and establishment_id = s.establishment_id and status = 'open';
  if not found then raise exception 'MESA_FECHADA'; end if;
  perform public._event(s.establishment_id, p_session_id, s.id, 'conta', s.name || ' mandou a conta para o caixa');
end $$;

create or replace function public.transfer_table(p_token uuid, p_session_id uuid, p_to_table uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_from_token(p_token); v_from text; v_to text;
begin
  select t.label into v_from from public.table_sessions ts join public.dining_tables t on t.id = ts.table_id
   where ts.id = p_session_id and ts.establishment_id = s.establishment_id and ts.status = 'open';
  if not found then raise exception 'MESA_FECHADA'; end if;
  select label into v_to from public.dining_tables where id = p_to_table and establishment_id = s.establishment_id and active;
  if not found then raise exception 'MESA_INVALIDA'; end if;
  begin
    update public.table_sessions set table_id = p_to_table where id = p_session_id;
  exception when unique_violation then raise exception 'MESA_OCUPADA';
  end;
  perform public._event(s.establishment_id, p_session_id, s.id, 'transferencia', 'Mesa ' || v_from || ' transferida para ' || v_to || ' por ' || s.name);
end $$;

-- permissões: só usuários logados (aparelho autorizado) chamam as funções públicas
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.current_establishment_id() to authenticated;
grant execute on function public.staff_login(uuid, text) to authenticated;
grant execute on function public.staff_logout(uuid) to authenticated;
grant execute on function public.open_table(uuid, uuid, int) to authenticated;
grant execute on function public.create_order(uuid, uuid, uuid, jsonb) to authenticated;
grant execute on function public.deliver_ready(uuid, uuid) to authenticated;
grant execute on function public.ack_call(uuid, uuid) to authenticated;
grant execute on function public.send_to_cashier(uuid, uuid) to authenticated;
grant execute on function public.transfer_table(uuid, uuid, uuid) to authenticated;
alter default privileges in schema public revoke execute on functions from public, anon;

-- tempo real
alter publication supabase_realtime add table public.table_sessions, public.order_items, public.orders, public.session_events, public.products;
