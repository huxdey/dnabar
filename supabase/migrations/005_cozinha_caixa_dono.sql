-- DNBAR etapa 2: cozinha, caixa (pagamentos, venda balcão, abertura/fechamento) e painel do dono

alter table public.establishments
  add column if not exists logo_url text,
  add column if not exists timezone text not null default 'America/Sao_Paulo';

alter table public.table_sessions
  add column if not exists service_fee_on boolean not null default true,
  add column if not exists discount_cents int not null default 0 check (discount_cents >= 0),
  add column if not exists closed_by uuid references public.staff(id);
create index if not exists table_sessions_closed_by_idx on public.table_sessions(closed_by);
create index if not exists table_sessions_closed_at_idx on public.table_sessions(establishment_id, closed_at);

create table public.cash_sessions(
  id uuid primary key default gen_random_uuid(),
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  status text not null default 'open' check (status in ('open','closed')),
  opened_by uuid not null references public.staff(id),
  opened_at timestamptz not null default now(),
  opening_cents int not null default 0 check (opening_cents >= 0),
  closed_by uuid references public.staff(id),
  closed_at timestamptz,
  expected_cash_cents int,
  counted_cash_cents int,
  difference_cents int,
  summary jsonb
);
create unique index one_open_cash_per_bar on public.cash_sessions(establishment_id) where status = 'open';
create index on public.cash_sessions(opened_by);
create index on public.cash_sessions(closed_by);

create table public.cash_movements(
  id uuid primary key default gen_random_uuid(),
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  cash_session_id uuid not null references public.cash_sessions(id),
  type text not null check (type in ('sangria','suprimento')),
  amount_cents int not null check (amount_cents > 0),
  reason text not null,
  created_by uuid not null references public.staff(id),
  created_at timestamptz not null default now()
);
create index on public.cash_movements(cash_session_id);
create index on public.cash_movements(created_by);
create index on public.cash_movements(establishment_id);

create table public.counter_sales(
  id uuid primary key default gen_random_uuid(),
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  number int not null,
  idempotency_key uuid not null,
  total_cents int not null,
  created_by uuid not null references public.staff(id),
  created_at timestamptz not null default now(),
  unique(establishment_id, idempotency_key)
);
create index on public.counter_sales(created_by);
create index on public.counter_sales(establishment_id, created_at);

create table public.counter_sale_items(
  id uuid primary key default gen_random_uuid(),
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  sale_id uuid not null references public.counter_sales(id),
  product_id uuid not null references public.products(id),
  name_snapshot text not null,
  unit_price_cents int not null,
  qty int not null check (qty between 1 and 99),
  created_at timestamptz not null default now()
);
create index on public.counter_sale_items(sale_id);
create index on public.counter_sale_items(product_id);
create index on public.counter_sale_items(establishment_id);

create table public.payments(
  id uuid primary key default gen_random_uuid(),
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  cash_session_id uuid not null references public.cash_sessions(id),
  session_id uuid references public.table_sessions(id),
  counter_sale_id uuid references public.counter_sales(id),
  method text not null check (method in ('pix','debito','credito','dinheiro','outro')),
  amount_cents int not null check (amount_cents > 0),
  received_cents int,
  change_cents int not null default 0,
  created_by uuid not null references public.staff(id),
  created_at timestamptz not null default now(),
  check (session_id is not null or counter_sale_id is not null)
);
create index on public.payments(cash_session_id);
create index on public.payments(session_id);
create index on public.payments(counter_sale_id);
create index on public.payments(created_by);
create index on public.payments(establishment_id, created_at);

alter table public.cash_sessions enable row level security;
alter table public.cash_movements enable row level security;
alter table public.counter_sales enable row level security;
alter table public.counter_sale_items enable row level security;
alter table public.payments enable row level security;
create policy "ler caixa" on public.cash_sessions for select to authenticated using (establishment_id = (select public.current_establishment_id()));
create policy "ler movimentos" on public.cash_movements for select to authenticated using (establishment_id = (select public.current_establishment_id()));
create policy "ler vendas balcao" on public.counter_sales for select to authenticated using (establishment_id = (select public.current_establishment_id()));
create policy "ler itens balcao" on public.counter_sale_items for select to authenticated using (establishment_id = (select public.current_establishment_id()));
create policy "ler pagamentos" on public.payments for select to authenticated using (establishment_id = (select public.current_establishment_id()));

-- ================= helpers =================
create or replace function public._money(c int) returns text language sql immutable set search_path = '' as $$
  select 'R$ ' || replace(to_char(coalesce(c,0) / 100.0, 'FM999999990.00'), '.', ',')
$$;

create or replace function public._staff_role(p_token uuid, p_roles text[]) returns public.staff
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_from_token(p_token);
begin
  if not (s.role = any(p_roles)) then raise exception 'SEM_PERMISSAO'; end if;
  return s;
end $$;

-- confere PIN de gerente (conta erros e bloqueia igual ao login)
create or replace function public._manager_ok(p_est uuid, p_mgr uuid, p_pin text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_sec public.staff_secrets;
begin
  perform 1 from public.staff where id = p_mgr and establishment_id = p_est and active and role = 'gerente';
  if not found then return false; end if;
  select * into v_sec from public.staff_secrets where staff_id = p_mgr for update;
  if not found or (v_sec.locked_until is not null and v_sec.locked_until > now()) then return false; end if;
  if p_pin is null or v_sec.pin_hash <> extensions.crypt(p_pin, v_sec.pin_hash) then
    update public.staff_secrets
       set failed_attempts = case when failed_attempts + 1 >= 5 then 0 else failed_attempts + 1 end,
           locked_until   = case when failed_attempts + 1 >= 5 then now() + interval '5 minutes' else null end
     where staff_id = p_mgr;
    return false;
  end if;
  update public.staff_secrets set failed_attempts = 0, locked_until = null where staff_id = p_mgr;
  return true;
end $$;

create or replace function public._bill(p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_sub int; v_fee int; v_paid int; v_s public.table_sessions; v_pct numeric; v_total int;
begin
  select * into v_s from public.table_sessions where id = p_session;
  select service_fee_pct into v_pct from public.establishments where id = v_s.establishment_id;
  select coalesce(sum(qty * unit_price_cents), 0)::int into v_sub from public.order_items where session_id = p_session and status <> 'cancelado';
  v_fee := case when v_s.service_fee_on then round(v_sub * v_pct / 100)::int else 0 end;
  select coalesce(sum(amount_cents), 0)::int into v_paid from public.payments where session_id = p_session;
  v_total := greatest(0, v_sub + v_fee - v_s.discount_cents);
  return jsonb_build_object('subtotal', v_sub, 'fee', v_fee, 'discount', v_s.discount_cents, 'total', v_total, 'paid', v_paid, 'remaining', greatest(0, v_total - v_paid));
end $$;

create or replace function public._open_cash(p_est uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select id from public.cash_sessions where establishment_id = p_est and status = 'open'
$$;

-- ================= cozinha / bar =================
create or replace function public.set_items_ready(p_token uuid, p_item_ids uuid[]) returns int
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_role(p_token, array['cozinha','bar','gerente']); v_n int := 0; r record;
begin
  for r in
    update public.order_items set status = 'pronto', ready_at = now()
     where id = any(p_item_ids) and establishment_id = s.establishment_id and status = 'preparo'
     returning session_id, qty, name_snapshot
  loop
    perform public._event(s.establishment_id, r.session_id, s.id, 'pronto', s.name || ' marcou pronto: ' || r.qty || ' ' || r.name_snapshot);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function public.undo_ready(p_token uuid, p_item_ids uuid[]) returns int
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_role(p_token, array['cozinha','bar','gerente']); v_n int;
begin
  update public.order_items set status = 'preparo', ready_at = null
   where id = any(p_item_ids) and establishment_id = s.establishment_id and status = 'pronto';
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ================= caixa =================
create or replace function public.cash_open(p_token uuid, p_opening_cents int) returns uuid
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_role(p_token, array['caixa','gerente']); v_id uuid;
begin
  begin
    insert into public.cash_sessions(establishment_id, opened_by, opening_cents)
    values (s.establishment_id, s.id, greatest(0, coalesce(p_opening_cents, 0))) returning id into v_id;
  exception when unique_violation then raise exception 'CAIXA_JA_ABERTO';
  end;
  perform public._event(s.establishment_id, null, s.id, 'caixa_aberto', s.name || ' abriu o caixa com ' || public._money(p_opening_cents) || ' de troco');
  return v_id;
end $$;

create or replace function public.cash_move(p_token uuid, p_type text, p_amount_cents int, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_role(p_token, array['caixa','gerente']); v_cash uuid := public._open_cash(s.establishment_id);
begin
  if v_cash is null then raise exception 'CAIXA_FECHADO'; end if;
  if p_type not in ('sangria','suprimento') or coalesce(p_amount_cents,0) <= 0 then raise exception 'VALOR_INVALIDO'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'MOTIVO_OBRIGATORIO'; end if;
  insert into public.cash_movements(establishment_id, cash_session_id, type, amount_cents, reason, created_by)
  values (s.establishment_id, v_cash, p_type, p_amount_cents, left(trim(p_reason), 200), s.id);
  perform public._event(s.establishment_id, null, s.id, p_type, s.name || ' fez ' || p_type || ' de ' || public._money(p_amount_cents) || ': ' || left(trim(p_reason), 200));
end $$;

create or replace function public._cash_summary(p_cash uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c public.cash_sessions; v_by jsonb; v_cash_in int; v_sup int; v_san int;
begin
  select * into c from public.cash_sessions where id = p_cash;
  select coalesce(jsonb_object_agg(method, total), '{}'::jsonb) into v_by
    from (select method, sum(amount_cents)::int total from public.payments where cash_session_id = p_cash group by method) x;
  select coalesce(sum(amount_cents), 0)::int into v_cash_in from public.payments where cash_session_id = p_cash and method = 'dinheiro';
  select coalesce(sum(amount_cents) filter (where type = 'suprimento'), 0)::int, coalesce(sum(amount_cents) filter (where type = 'sangria'), 0)::int
    into v_sup, v_san from public.cash_movements where cash_session_id = p_cash;
  return jsonb_build_object('opening', c.opening_cents, 'by_method', v_by, 'cash_sales', v_cash_in, 'supply', v_sup, 'withdrawal', v_san,
    'expected_cash', c.opening_cents + v_cash_in + v_sup - v_san,
    'total', (select coalesce(sum(amount_cents),0)::int from public.payments where cash_session_id = p_cash));
end $$;

create or replace function public.cash_close(p_token uuid, p_counted_cents int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_role(p_token, array['caixa','gerente']); v_cash uuid := public._open_cash(s.establishment_id); v_sum jsonb; v_exp int;
begin
  if v_cash is null then raise exception 'CAIXA_FECHADO'; end if;
  if p_counted_cents is null or p_counted_cents < 0 then raise exception 'VALOR_INVALIDO'; end if;
  v_sum := public._cash_summary(v_cash);
  v_exp := (v_sum->>'expected_cash')::int;
  update public.cash_sessions set status = 'closed', closed_by = s.id, closed_at = now(),
    expected_cash_cents = v_exp, counted_cash_cents = p_counted_cents, difference_cents = p_counted_cents - v_exp, summary = v_sum
   where id = v_cash;
  perform public._event(s.establishment_id, null, s.id, 'caixa_fechado', s.name || ' fechou o caixa. Esperado em dinheiro ' || public._money(v_exp) || ', contado ' || public._money(p_counted_cents) || ' (diferença ' || public._money(p_counted_cents - v_exp) || ')');
  return v_sum || jsonb_build_object('counted', p_counted_cents, 'difference', p_counted_cents - v_exp);
end $$;

create or replace function public.cash_status(p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_role(p_token, array['caixa','gerente']); v_cash uuid := public._open_cash(s.establishment_id); c public.cash_sessions;
begin
  if v_cash is null then return jsonb_build_object('open', false); end if;
  select * into c from public.cash_sessions where id = v_cash;
  return jsonb_build_object('open', true, 'id', c.id, 'opened_at', c.opened_at,
    'opened_by', (select name from public.staff where id = c.opened_by)) || public._cash_summary(v_cash);
end $$;

create or replace function public.set_service_fee(p_token uuid, p_session_id uuid, p_on boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_role(p_token, array['caixa','gerente']);
begin
  update public.table_sessions set service_fee_on = p_on where id = p_session_id and establishment_id = s.establishment_id and status = 'open';
  if not found then raise exception 'MESA_FECHADA'; end if;
  perform public._event(s.establishment_id, p_session_id, s.id, 'servico', s.name || case when p_on then ' incluiu' else ' retirou' end || ' a taxa de serviço');
end $$;

create or replace function public.set_discount(p_token uuid, p_session_id uuid, p_amount_cents int, p_reason text, p_mgr uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_role(p_token, array['caixa','gerente','garcom']); b jsonb; m text;
begin
  if not public._manager_ok(s.establishment_id, p_mgr, p_pin) then return jsonb_build_object('ok', false, 'error', 'PIN_GERENTE_INVALIDO'); end if;
  perform 1 from public.table_sessions where id = p_session_id and establishment_id = s.establishment_id and status = 'open' for update;
  if not found then raise exception 'MESA_FECHADA'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'MOTIVO_OBRIGATORIO'; end if;
  b := public._bill(p_session_id);
  if p_amount_cents is null or p_amount_cents < 0 or p_amount_cents > (b->>'subtotal')::int + (b->>'fee')::int then raise exception 'VALOR_INVALIDO'; end if;
  update public.table_sessions set discount_cents = p_amount_cents where id = p_session_id;
  select name into m from public.staff where id = p_mgr;
  perform public._event(s.establishment_id, p_session_id, s.id, 'desconto', 'Desconto de ' || public._money(p_amount_cents) || ' autorizado por ' || m || ' (pedido por ' || s.name || '): ' || left(trim(p_reason),200),
    jsonb_build_object('amount', p_amount_cents, 'manager', p_mgr, 'reason', left(trim(p_reason),200)));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.cancel_item(p_token uuid, p_item_id uuid, p_reason text, p_mgr uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_role(p_token, array['caixa','gerente','garcom']); it public.order_items; m text;
begin
  if not public._manager_ok(s.establishment_id, p_mgr, p_pin) then return jsonb_build_object('ok', false, 'error', 'PIN_GERENTE_INVALIDO'); end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'MOTIVO_OBRIGATORIO'; end if;
  select oi.* into it from public.order_items oi join public.table_sessions ts on ts.id = oi.session_id
   where oi.id = p_item_id and oi.establishment_id = s.establishment_id and ts.status = 'open' and oi.status <> 'cancelado' for update of oi;
  if not found then raise exception 'ITEM_INVALIDO'; end if;
  select name into m from public.staff where id = p_mgr;
  update public.order_items set status = 'cancelado', cancelled_at = now(), cancelled_by = p_mgr, cancel_reason = left(trim(p_reason),200) where id = p_item_id;
  perform public._event(s.establishment_id, it.session_id, s.id, 'cancelamento', it.qty || ' ' || it.name_snapshot || ' cancelado. Autorizado por ' || m || ' (pedido por ' || s.name || '): ' || left(trim(p_reason),200),
    jsonb_build_object('item', p_item_id, 'manager', p_mgr, 'value', it.qty * it.unit_price_cents));
  return jsonb_build_object('ok', true);
end $$;

-- pagamento de mesa (caixa no balcão ou garçom com a maquininha). Fecha a mesa quando zera.
create or replace function public.pay(p_token uuid, p_session_id uuid, p_method text, p_amount_cents int, p_received_cents int default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_role(p_token, array['caixa','gerente','garcom']); v_cash uuid := public._open_cash(s.establishment_id);
  b jsonb; v_rem int; v_change int := 0; v_label text;
begin
  if v_cash is null then raise exception 'CAIXA_FECHADO'; end if;
  if p_method not in ('pix','debito','credito','dinheiro','outro') then raise exception 'FORMA_INVALIDA'; end if;
  select t.label into v_label from public.table_sessions ts join public.dining_tables t on t.id = ts.table_id
   where ts.id = p_session_id and ts.establishment_id = s.establishment_id and ts.status = 'open' for update of ts;
  if not found then raise exception 'MESA_FECHADA'; end if;
  b := public._bill(p_session_id); v_rem := (b->>'remaining')::int;
  if p_amount_cents is null or p_amount_cents <= 0 or p_amount_cents > v_rem then raise exception 'VALOR_INVALIDO'; end if;
  if p_method = 'dinheiro' and p_received_cents is not null then
    if p_received_cents < p_amount_cents then raise exception 'RECEBIDO_MENOR'; end if;
    v_change := p_received_cents - p_amount_cents;
  end if;
  insert into public.payments(establishment_id, cash_session_id, session_id, method, amount_cents, received_cents, change_cents, created_by)
  values (s.establishment_id, v_cash, p_session_id, p_method, p_amount_cents, p_received_cents, v_change, s.id);
  perform public._event(s.establishment_id, p_session_id, s.id, 'pagamento', s.name || ' recebeu ' || public._money(p_amount_cents) || ' (' || p_method || ')');
  v_rem := v_rem - p_amount_cents;
  if v_rem = 0 then
    update public.table_sessions set status = 'closed', closed_at = now(), closed_by = s.id, flag = null where id = p_session_id;
    perform public._event(s.establishment_id, p_session_id, s.id, 'mesa_fechada', 'Mesa ' || v_label || ' fechada por ' || s.name);
  end if;
  return jsonb_build_object('remaining', v_rem, 'closed', v_rem = 0, 'change', v_change);
end $$;

-- venda balcão (sem mesa): bala, chiclete, água pra viagem...
create or replace function public.counter_sale(p_token uuid, p_key uuid, p_items jsonb, p_method text, p_received_cents int default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_role(p_token, array['caixa','gerente']); v_cash uuid := public._open_cash(s.establishment_id);
  v_id uuid; v_no int; it jsonb; p public.products; v_price int; v_name text; v_size text; v_qty int; v_total int := 0; v_change int := 0; v_sum text;
begin
  select number into v_no from public.counter_sales where establishment_id = s.establishment_id and idempotency_key = p_key;
  if found then return jsonb_build_object('number', v_no, 'duplicate', true); end if;
  if v_cash is null then raise exception 'CAIXA_FECHADO'; end if;
  if p_method not in ('pix','debito','credito','dinheiro','outro') then raise exception 'FORMA_INVALIDA'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 50 then raise exception 'PEDIDO_VAZIO'; end if;
  update public.establishments set order_seq = order_seq + 1 where id = s.establishment_id returning order_seq into v_no;
  insert into public.counter_sales(establishment_id, number, idempotency_key, total_cents, created_by)
  values (s.establishment_id, v_no, p_key, 0, s.id) returning id into v_id;
  for it in select * from jsonb_array_elements(p_items) loop
    select * into p from public.products where id = (it->>'product_id')::uuid and establishment_id = s.establishment_id and active;
    if not found then raise exception 'PRODUTO_INVALIDO'; end if;
    if not p.available then raise exception 'PRODUTO_ESGOTADO:%', p.name; end if;
    v_size := nullif(it->>'size','');
    if p.sizes is not null and jsonb_array_length(p.sizes) > 0 then
      select (e->>'v')::int into v_price from jsonb_array_elements(p.sizes) e where e->>'l' = v_size;
      if v_price is null then raise exception 'TAMANHO_INVALIDO:%', p.name; end if;
      v_name := p.name || ' (' || lower(v_size) || ')';
    else
      v_price := p.price_cents; v_name := p.name;
      if v_price is null then raise exception 'SEM_PRECO:%', p.name; end if;
    end if;
    v_qty := (it->>'qty')::int;
    if v_qty is null or v_qty < 1 or v_qty > 99 then raise exception 'QUANTIDADE_INVALIDA'; end if;
    insert into public.counter_sale_items(establishment_id, sale_id, product_id, name_snapshot, unit_price_cents, qty)
    values (s.establishment_id, v_id, p.id, v_name, v_price, v_qty);
    v_total := v_total + v_price * v_qty;
    v_sum := coalesce(v_sum || ', ', '') || v_qty || ' ' || v_name;
  end loop;
  update public.counter_sales set total_cents = v_total where id = v_id;
  if p_method = 'dinheiro' and p_received_cents is not null then
    if p_received_cents < v_total then raise exception 'RECEBIDO_MENOR'; end if;
    v_change := p_received_cents - v_total;
  end if;
  insert into public.payments(establishment_id, cash_session_id, counter_sale_id, method, amount_cents, received_cents, change_cents, created_by)
  values (s.establishment_id, v_cash, v_id, p_method, v_total, p_received_cents, v_change, s.id);
  perform public._event(s.establishment_id, null, s.id, 'balcao', s.name || ' vendeu no balcão #' || v_no || ': ' || v_sum || ' = ' || public._money(v_total) || ' (' || p_method || ')');
  return jsonb_build_object('number', v_no, 'total', v_total, 'change', v_change, 'duplicate', false);
end $$;

-- ================= dono =================
create or replace function public._owner_est() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v uuid;
begin
  select establishment_id into v from public.members where user_id = (select auth.uid()) and role = 'owner';
  if v is null then raise exception 'SEM_PERMISSAO'; end if;
  return v;
end $$;

create or replace function public.owner_report(p_from timestamptz, p_to timestamptz) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_est uuid := public._owner_est(); v_tz text; v_prev_from timestamptz := p_from - (p_to - p_from); r jsonb;
begin
  select timezone into v_tz from public.establishments where id = v_est;
  with
  pay as (select * from public.payments where establishment_id = v_est and created_at >= p_from and created_at < p_to),
  closed as (select * from public.table_sessions where establishment_id = v_est and status = 'closed' and closed_at >= p_from and closed_at < p_to),
  sold as (
    select oi.product_id, oi.name_snapshot, oi.qty, oi.qty * oi.unit_price_cents as val, oi.created_at, o.created_by
      from public.order_items oi join public.orders o on o.id = oi.order_id
     where oi.establishment_id = v_est and oi.status <> 'cancelado' and oi.created_at >= p_from and oi.created_at < p_to
    union all
    select ci.product_id, ci.name_snapshot, ci.qty, ci.qty * ci.unit_price_cents, ci.created_at, cs.created_by
      from public.counter_sale_items ci join public.counter_sales cs on cs.id = ci.sale_id
     where ci.establishment_id = v_est and ci.created_at >= p_from and ci.created_at < p_to),
  prod as (select name_snapshot as name, sum(qty)::int as qty, sum(val)::int as total from sold group by name_snapshot)
  select jsonb_build_object(
    'revenue', (select coalesce(sum(amount_cents),0)::int from pay),
    'revenue_prev', (select coalesce(sum(amount_cents),0)::int from public.payments where establishment_id = v_est and created_at >= v_prev_from and created_at < p_from),
    'tables_closed', (select count(*)::int from closed),
    'people', (select coalesce(sum(people),0)::int from closed),
    'table_revenue', (select coalesce(sum(amount_cents),0)::int from pay where session_id is not null),
    'counter_count', (select count(*)::int from public.counter_sales where establishment_id = v_est and created_at >= p_from and created_at < p_to),
    'counter_revenue', (select coalesce(sum(amount_cents),0)::int from pay where counter_sale_id is not null),
    'items_sold', (select coalesce(sum(qty),0)::int from sold),
    'open_tables', (select count(*)::int from public.table_sessions where establishment_id = v_est and status = 'open'),
    'by_method', (select coalesce(jsonb_object_agg(method, t), '{}'::jsonb) from (select method, sum(amount_cents)::int t from pay group by method) x),
    'top', (select coalesce(jsonb_agg(x order by x.qty desc, x.total desc), '[]'::jsonb) from (select * from prod order by qty desc, total desc limit 10) x),
    'bottom', (select coalesce(jsonb_agg(x order by x.qty asc, x.total asc), '[]'::jsonb) from (select * from prod order by qty asc, total asc limit 5) x),
    'not_sold', (select coalesce(jsonb_agg(p.name order by p.name), '[]'::jsonb) from public.products p
                  where p.establishment_id = v_est and p.active and not exists (select 1 from sold where sold.product_id = p.id)),
    'by_staff', (select coalesce(jsonb_agg(x order by x.total desc), '[]'::jsonb) from (
                  select st.name, st.role_label as role, sum(sold.val)::int as total, sum(sold.qty)::int as qty
                    from sold join public.staff st on st.id = sold.created_by group by st.name, st.role_label) x),
    'by_hour', (select coalesce(jsonb_object_agg(h, t), '{}'::jsonb) from (
                  select extract(hour from (sold.created_at at time zone v_tz))::int h, sum(sold.val)::int t from sold group by 1) x),
    'cancellations', (select coalesce(jsonb_agg(x order by x.at desc), '[]'::jsonb) from (
                  select oi.cancelled_at as at, oi.qty, oi.name_snapshot as item, oi.qty * oi.unit_price_cents as value, oi.cancel_reason as reason, m.name as by
                    from public.order_items oi left join public.staff m on m.id = oi.cancelled_by
                   where oi.establishment_id = v_est and oi.status = 'cancelado' and oi.cancelled_at >= p_from and oi.cancelled_at < p_to) x),
    'discounts', (select coalesce(jsonb_agg(x order by x.at desc), '[]'::jsonb) from (
                  select e.created_at as at, (e.meta->>'amount')::int as value, e.meta->>'reason' as reason, m.name as by, st.name as asked_by
                    from public.session_events e left join public.staff m on m.id = (e.meta->>'manager')::uuid left join public.staff st on st.id = e.staff_id
                   where e.establishment_id = v_est and e.type = 'desconto' and e.created_at >= p_from and e.created_at < p_to) x),
    'cash', (select coalesce(jsonb_agg(x order by x.opened_at desc), '[]'::jsonb) from (
                  select c.opened_at, c.closed_at, c.status, c.difference_cents as difference, c.expected_cash_cents as expected, c.counted_cash_cents as counted,
                         ob.name as opened_by, cb.name as closed_by
                    from public.cash_sessions c left join public.staff ob on ob.id = c.opened_by left join public.staff cb on cb.id = c.closed_by
                   where c.establishment_id = v_est and c.opened_at < p_to and coalesce(c.closed_at, now()) >= p_from) x)
  ) into r;
  return r;
end $$;

create or replace function public.owner_update_product(p_product_id uuid, p_price_cents int, p_sizes jsonb, p_available boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_est uuid := public._owner_est(); p public.products;
begin
  select * into p from public.products where id = p_product_id and establishment_id = v_est for update;
  if not found then raise exception 'PRODUTO_INVALIDO'; end if;
  if p_price_cents is not null and p_price_cents < 0 then raise exception 'VALOR_INVALIDO'; end if;
  update public.products set
    price_cents = case when p.sizes is not null and jsonb_array_length(p.sizes) > 0 then null else p_price_cents end,
    sizes = case when p.sizes is not null and jsonb_array_length(p.sizes) > 0 and p_sizes is not null then p_sizes else p.sizes end,
    available = coalesce(p_available, p.available),
    updated_at = now()
   where id = p_product_id;
  perform public._event(v_est, null, null, 'produto', 'Dono alterou ' || p.name, jsonb_build_object('price', p_price_cents, 'sizes', p_sizes, 'available', p_available));
end $$;

create or replace function public.whoami() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('role', role, 'establishment_id', establishment_id) from public.members where user_id = (select auth.uid())
$$;

-- ================= permissões =================
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.current_establishment_id() to authenticated;
grant execute on function public.whoami() to authenticated;
grant execute on function public.staff_login(uuid, text) to authenticated;
grant execute on function public.staff_logout(uuid) to authenticated;
grant execute on function public.open_table(uuid, uuid, int) to authenticated;
grant execute on function public.create_order(uuid, uuid, uuid, jsonb) to authenticated;
grant execute on function public.deliver_ready(uuid, uuid) to authenticated;
grant execute on function public.ack_call(uuid, uuid) to authenticated;
grant execute on function public.send_to_cashier(uuid, uuid) to authenticated;
grant execute on function public.transfer_table(uuid, uuid, uuid) to authenticated;
grant execute on function public.set_items_ready(uuid, uuid[]) to authenticated;
grant execute on function public.undo_ready(uuid, uuid[]) to authenticated;
grant execute on function public.cash_open(uuid, int) to authenticated;
grant execute on function public.cash_move(uuid, text, int, text) to authenticated;
grant execute on function public.cash_close(uuid, int) to authenticated;
grant execute on function public.cash_status(uuid) to authenticated;
grant execute on function public.set_service_fee(uuid, uuid, boolean) to authenticated;
grant execute on function public.set_discount(uuid, uuid, int, text, uuid, text) to authenticated;
grant execute on function public.cancel_item(uuid, uuid, text, uuid, text) to authenticated;
grant execute on function public.pay(uuid, uuid, text, int, int) to authenticated;
grant execute on function public.counter_sale(uuid, uuid, jsonb, text, int) to authenticated;
grant execute on function public.owner_report(timestamptz, timestamptz) to authenticated;
grant execute on function public.owner_update_product(uuid, int, jsonb, boolean) to authenticated;
grant execute on function public.block_public_signup() to supabase_auth_admin;

alter publication supabase_realtime add table public.payments, public.cash_sessions, public.counter_sales, public.establishments;
