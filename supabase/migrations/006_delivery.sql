-- DNBAR etapa 3: módulo de delivery (plano Salão + Delivery)

alter table public.establishments
  add column if not exists slug text unique,
  add column if not exists plan text not null default 'salao' check (plan in ('salao','salao_delivery')),
  add column if not exists delivery_open boolean not null default false,
  add column if not exists whatsapp text,
  add column if not exists pix_key text,
  add column if not exists pix_key_type text check (pix_key_type in ('cpf','cnpj','email','telefone','aleatoria')),
  add column if not exists pix_merchant_name text,
  add column if not exists pix_city text,
  add column if not exists delivery_fee_cents int not null default 0 check (delivery_fee_cents >= 0),
  add column if not exists min_order_cents int not null default 0 check (min_order_cents >= 0),
  add column if not exists delivery_eta_min int not null default 45 check (delivery_eta_min between 5 and 240),
  add column if not exists delivery_seq int not null default 0;

create table public.delivery_orders(
  id uuid primary key default gen_random_uuid(),
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  number int not null,
  tracking_token uuid not null unique default gen_random_uuid(),
  idempotency_key uuid not null,
  customer_name text not null,
  customer_phone text not null,
  address jsonb not null,
  note text,
  status text not null default 'novo' check (status in ('novo','aceito','preparo','pronto','saiu','entregue','recusado','cancelado')),
  payment_method text not null check (payment_method in ('pix','dinheiro','cartao')),
  payment_status text not null default 'pendente' check (payment_status in ('pendente','confirmado')),
  payment_confirmed_by uuid references public.staff(id),
  payment_confirmed_at timestamptz,
  change_for_cents int,
  subtotal_cents int not null,
  delivery_fee_cents int not null,
  total_cents int not null,
  pix_payload text,
  reject_reason text,
  client_ip text,
  handled_by uuid references public.staff(id),
  created_at timestamptz not null default now(),
  accepted_at timestamptz, ready_at timestamptz, dispatched_at timestamptz, delivered_at timestamptz, closed_at timestamptz,
  unique(establishment_id, idempotency_key)
);
create index on public.delivery_orders(establishment_id, status);
create index on public.delivery_orders(establishment_id, created_at);
create index on public.delivery_orders(establishment_id, customer_phone, created_at);
create index on public.delivery_orders(payment_confirmed_by);
create index on public.delivery_orders(handled_by);

create table public.delivery_order_items(
  id uuid primary key default gen_random_uuid(),
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  delivery_order_id uuid not null references public.delivery_orders(id) on delete cascade,
  product_id uuid not null references public.products(id),
  name_snapshot text not null,
  size_label text,
  unit_price_cents int not null,
  qty int not null check (qty between 1 and 99),
  note text,
  area text not null check (area in ('cozinha','bar'))
);
create index on public.delivery_order_items(delivery_order_id);
create index on public.delivery_order_items(product_id);
create index on public.delivery_order_items(establishment_id);

alter table public.payments add column if not exists delivery_order_id uuid references public.delivery_orders(id);
create index if not exists payments_delivery_order_idx on public.payments(delivery_order_id);
alter table public.payments drop constraint if exists payments_check;
alter table public.payments add constraint payments_origem_check check (session_id is not null or counter_sale_id is not null or delivery_order_id is not null);

alter table public.delivery_orders enable row level security;
alter table public.delivery_order_items enable row level security;
create policy "ler delivery" on public.delivery_orders for select to authenticated using (establishment_id = (select public.current_establishment_id()));
create policy "ler itens delivery" on public.delivery_order_items for select to authenticated using (establishment_id = (select public.current_establishment_id()));

-- ================= Pix copia e cola (BR Code estático) =================
create or replace function public._crc16(p text) returns text language plpgsql immutable set search_path = '' as $$
declare crc int := 65535; b bytea := convert_to(p, 'UTF8'); i int; j int;
begin
  for i in 0 .. length(b) - 1 loop
    crc := crc # (get_byte(b, i) << 8);
    for j in 1 .. 8 loop
      if (crc & 32768) <> 0 then crc := ((crc << 1) # 4129) & 65535; else crc := (crc << 1) & 65535; end if;
    end loop;
  end loop;
  return upper(lpad(to_hex(crc), 4, '0'));
end $$;

create or replace function public._emv(p_id text, p_v text) returns text language sql immutable set search_path = '' as $$
  select p_id || lpad(length(p_v)::text, 2, '0') || p_v
$$;

create or replace function public._pix_clean(t text, n int) returns text language sql immutable set search_path = '' as $$
  select left(trim(regexp_replace(upper(translate(coalesce(t,''), 'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ', 'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUC')), '[^A-Z0-9 ]', '', 'g')), n)
$$;

create or replace function public._pix_payload(p_key text, p_name text, p_city text, p_cents int, p_txid text) returns text
language plpgsql immutable set search_path = '' as $$
declare v text;
begin
  v := public._emv('00', '01')
    || public._emv('26', public._emv('00', 'br.gov.bcb.pix') || public._emv('01', p_key))
    || public._emv('52', '0000') || public._emv('53', '986')
    || public._emv('54', to_char(p_cents / 100.0, 'FM99999990.00'))
    || public._emv('58', 'BR')
    || public._emv('59', coalesce(nullif(public._pix_clean(p_name, 25), ''), 'RESTAURANTE'))
    || public._emv('60', coalesce(nullif(public._pix_clean(p_city, 15), ''), 'BRASIL'))
    || public._emv('62', public._emv('05', coalesce(nullif(regexp_replace(upper(p_txid), '[^A-Z0-9]', '', 'g'), ''), '***')))
    || '6304';
  return v || public._crc16(v);
end $$;

-- ================= funções públicas (cliente sem login) =================
create or replace function public.public_menu(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare e public.establishments;
begin
  select * into e from public.establishments where slug = lower(p_slug) and plan = 'salao_delivery';
  if not found then raise exception 'RESTAURANTE_NAO_ENCONTRADO'; end if;
  return jsonb_build_object('name', e.name, 'logo_url', e.logo_url, 'open', e.delivery_open, 'fee', e.delivery_fee_cents,
    'min', e.min_order_cents, 'eta', e.delivery_eta_min, 'whatsapp', e.whatsapp, 'pix', e.pix_key is not null,
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'products', ps) order by c.sort), '[]'::jsonb)
      from public.categories c
      cross join lateral (select jsonb_agg(jsonb_build_object('id', p.id, 'number', p.number, 'name', p.name, 'description', null,
            'image_url', p.image_url, 'icon', p.icon, 'price', p.price_cents, 'sizes', p.sizes, 'available', p.available) order by p.sort) ps
          from public.products p where p.category_id = c.id and p.active and (p.price_cents is not null or (p.sizes is not null and jsonb_array_length(p.sizes) > 0))) x
      where c.establishment_id = e.id and c.active and ps is not null));
end $$;

create or replace function public.public_create_order(p_slug text, p_key uuid, p_name text, p_phone text, p_address jsonb, p_items jsonb,
  p_method text, p_change_for_cents int default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare e public.establishments; v_id uuid; v_no int; v_tok uuid; it jsonb; p public.products; v_area text; v_price int; v_name text; v_size text; v_qty int;
  v_sub int := 0; v_total int; v_phone text := regexp_replace(coalesce(p_phone,''), '\D', '', 'g'); v_ip text; v_addr jsonb; v_pix text;
begin
  select * into e from public.establishments where slug = lower(p_slug) and plan = 'salao_delivery' for update;
  if not found then raise exception 'RESTAURANTE_NAO_ENCONTRADO'; end if;
  select number, tracking_token into v_no, v_tok from public.delivery_orders where establishment_id = e.id and idempotency_key = p_key;
  if found then return jsonb_build_object('number', v_no, 'token', v_tok, 'duplicate', true); end if;
  if not e.delivery_open then raise exception 'DELIVERY_FECHADO'; end if;
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'NOME_INVALIDO'; end if;
  if length(v_phone) < 10 or length(v_phone) > 13 then raise exception 'TELEFONE_INVALIDO'; end if;
  if coalesce(trim(p_address->>'rua'),'') = '' or coalesce(trim(p_address->>'numero'),'') = '' or coalesce(trim(p_address->>'bairro'),'') = '' then raise exception 'ENDERECO_INVALIDO'; end if;
  v_addr := jsonb_build_object('rua', left(trim(p_address->>'rua'),120), 'numero', left(trim(p_address->>'numero'),20), 'complemento', left(trim(coalesce(p_address->>'complemento','')),80),
    'bairro', left(trim(p_address->>'bairro'),80), 'referencia', left(trim(coalesce(p_address->>'referencia','')),120));
  if p_method not in ('pix','dinheiro','cartao') then raise exception 'FORMA_INVALIDA'; end if;
  if p_method = 'pix' and e.pix_key is null then raise exception 'FORMA_INVALIDA'; end if;
  -- anti-spam
  begin v_ip := split_part(coalesce((current_setting('request.headers', true)::json)->>'x-forwarded-for', ''), ',', 1); exception when others then v_ip := null; end;
  if (select count(*) from public.delivery_orders where establishment_id = e.id and customer_phone = v_phone and created_at > now() - interval '10 minutes' and status in ('novo','aceito')) >= 3
     or (v_ip is not null and v_ip <> '' and (select count(*) from public.delivery_orders where client_ip = v_ip and created_at > now() - interval '10 minutes') >= 5)
     or (select count(*) from public.delivery_orders where establishment_id = e.id and created_at > now() - interval '1 minute') >= 20 then
    raise exception 'MUITOS_PEDIDOS';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 50 then raise exception 'PEDIDO_VAZIO'; end if;

  update public.establishments set delivery_seq = delivery_seq + 1 where id = e.id returning delivery_seq into v_no;
  insert into public.delivery_orders(establishment_id, number, idempotency_key, customer_name, customer_phone, address, note, payment_method, change_for_cents, subtotal_cents, delivery_fee_cents, total_cents, client_ip)
  values (e.id, v_no, p_key, left(trim(p_name),60), v_phone, v_addr, left(nullif(trim(coalesce(p_note,'')),''),200), p_method, null, 0, e.delivery_fee_cents, 0, nullif(v_ip,''))
  returning id, tracking_token into v_id, v_tok;

  for it in select * from jsonb_array_elements(p_items) loop
    select * into p from public.products where id = (it->>'product_id')::uuid and establishment_id = e.id and active;
    if not found then raise exception 'PRODUTO_INVALIDO'; end if;
    if not p.available then raise exception 'PRODUTO_ESGOTADO:%', p.name; end if;
    select c.area into v_area from public.categories c where c.id = p.category_id;
    v_size := nullif(it->>'size','');
    if p.sizes is not null and jsonb_array_length(p.sizes) > 0 then
      select (x->>'v')::int into v_price from jsonb_array_elements(p.sizes) x where x->>'l' = v_size;
      if v_price is null then raise exception 'TAMANHO_INVALIDO:%', p.name; end if;
      v_name := p.name || ' (' || lower(v_size) || ')';
    else
      v_price := p.price_cents; v_size := null; v_name := p.name;
      if v_price is null then raise exception 'SEM_PRECO:%', p.name; end if;
    end if;
    v_qty := (it->>'qty')::int;
    if v_qty is null or v_qty < 1 or v_qty > 99 then raise exception 'QUANTIDADE_INVALIDA'; end if;
    insert into public.delivery_order_items(establishment_id, delivery_order_id, product_id, name_snapshot, size_label, unit_price_cents, qty, note, area)
    values (e.id, v_id, p.id, v_name, v_size, v_price, v_qty, left(nullif(trim(coalesce(it->>'note','')),''),120), v_area);
    v_sub := v_sub + v_price * v_qty;
  end loop;
  if v_sub < e.min_order_cents then raise exception 'PEDIDO_MINIMO:%', public._money(e.min_order_cents); end if;
  v_total := v_sub + e.delivery_fee_cents;
  if p_method = 'dinheiro' and p_change_for_cents is not null and p_change_for_cents > 0 and p_change_for_cents < v_total then raise exception 'TROCO_MENOR'; end if;
  if p_method = 'pix' then v_pix := public._pix_payload(e.pix_key, coalesce(e.pix_merchant_name, e.name), coalesce(e.pix_city, 'BRASIL'), v_total, 'DNB' || v_no); end if;
  update public.delivery_orders set subtotal_cents = v_sub, total_cents = v_total, pix_payload = v_pix,
    change_for_cents = case when p_method = 'dinheiro' and coalesce(p_change_for_cents,0) > 0 then p_change_for_cents end
   where id = v_id;
  perform public._event(e.id, null, null, 'delivery_novo', 'Delivery #' || v_no || ' de ' || left(trim(p_name),60) || ': ' || public._money(v_total));
  return jsonb_build_object('number', v_no, 'token', v_tok, 'total', v_total, 'duplicate', false);
end $$;

create or replace function public.public_track(p_token uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('number', o.number, 'status', o.status, 'payment_method', o.payment_method, 'payment_status', o.payment_status,
    'subtotal', o.subtotal_cents, 'fee', o.delivery_fee_cents, 'total', o.total_cents, 'change_for', o.change_for_cents,
    'pix', case when o.payment_method = 'pix' and o.payment_status = 'pendente' and o.status not in ('recusado','cancelado') then o.pix_payload end,
    'reject_reason', o.reject_reason, 'created_at', o.created_at, 'accepted_at', o.accepted_at, 'ready_at', o.ready_at,
    'dispatched_at', o.dispatched_at, 'delivered_at', o.delivered_at, 'address', o.address, 'name', o.customer_name,
    'bar', jsonb_build_object('name', e.name, 'whatsapp', e.whatsapp, 'eta', e.delivery_eta_min, 'slug', e.slug),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('qty', i.qty, 'name', i.name_snapshot, 'total', i.qty * i.unit_price_cents, 'note', i.note)), '[]'::jsonb)
              from public.delivery_order_items i where i.delivery_order_id = o.id))
    from public.delivery_orders o join public.establishments e on e.id = o.establishment_id
   where o.tracking_token = p_token
$$;

-- ================= restaurante =================
create or replace function public.delivery_action(p_token uuid, p_order_id uuid, p_action text, p_extra jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_from_token(p_token); o public.delivery_orders; v_cash uuid; v_method text; v_new text;
begin
  select * into o from public.delivery_orders where id = p_order_id and establishment_id = s.establishment_id for update;
  if not found then raise exception 'PEDIDO_INVALIDO'; end if;
  if p_action = 'pronto' then
    if s.role not in ('cozinha','bar','caixa','gerente') then raise exception 'SEM_PERMISSAO'; end if;
  elsif s.role not in ('caixa','gerente') then raise exception 'SEM_PERMISSAO';
  end if;

  if p_action = 'aceitar' then
    if o.status <> 'novo' then raise exception 'STATUS_INVALIDO'; end if;
    v_new := case when o.payment_method = 'pix' and o.payment_status = 'pendente' then 'aceito' else 'preparo' end;
    update public.delivery_orders set status = v_new, accepted_at = now(), handled_by = s.id where id = o.id;
  elsif p_action = 'recusar' then
    if o.status not in ('novo','aceito') then raise exception 'STATUS_INVALIDO'; end if;
    update public.delivery_orders set status = 'recusado', reject_reason = left(coalesce(nullif(trim(p_extra->>'reason'),''),'Recusado pelo restaurante'),200), closed_at = now(), handled_by = s.id where id = o.id;
  elsif p_action = 'confirmar_pix' then
    if o.payment_method <> 'pix' or o.payment_status <> 'pendente' or o.status in ('recusado','cancelado') then raise exception 'STATUS_INVALIDO'; end if;
    v_cash := public._open_cash(s.establishment_id); if v_cash is null then raise exception 'CAIXA_FECHADO'; end if;
    insert into public.payments(establishment_id, cash_session_id, delivery_order_id, method, amount_cents, created_by) values (s.establishment_id, v_cash, o.id, 'pix', o.total_cents, s.id);
    update public.delivery_orders set payment_status = 'confirmado', payment_confirmed_by = s.id, payment_confirmed_at = now(),
      status = case when status = 'aceito' then 'preparo' else status end where id = o.id;
  elsif p_action = 'pronto' then
    if o.status <> 'preparo' then raise exception 'STATUS_INVALIDO'; end if;
    update public.delivery_orders set status = 'pronto', ready_at = now() where id = o.id;
  elsif p_action = 'saiu' then
    if o.status not in ('preparo','pronto') then raise exception 'STATUS_INVALIDO'; end if;
    update public.delivery_orders set status = 'saiu', dispatched_at = now(), ready_at = coalesce(ready_at, now()) where id = o.id;
  elsif p_action = 'entregue' then
    if o.status <> 'saiu' then raise exception 'STATUS_INVALIDO'; end if;
    if o.payment_status = 'pendente' then
      v_method := case when o.payment_method = 'dinheiro' then 'dinheiro' when o.payment_method = 'pix' then 'pix' else coalesce(nullif(p_extra->>'method',''), 'credito') end;
      if v_method not in ('pix','debito','credito','dinheiro') then raise exception 'FORMA_INVALIDA'; end if;
      v_cash := public._open_cash(s.establishment_id); if v_cash is null then raise exception 'CAIXA_FECHADO'; end if;
      insert into public.payments(establishment_id, cash_session_id, delivery_order_id, method, amount_cents, received_cents, change_cents, created_by)
      values (s.establishment_id, v_cash, o.id, v_method, o.total_cents, case when v_method = 'dinheiro' then coalesce(o.change_for_cents, o.total_cents) end,
              case when v_method = 'dinheiro' and o.change_for_cents is not null then o.change_for_cents - o.total_cents else 0 end, s.id);
      update public.delivery_orders set payment_status = 'confirmado', payment_confirmed_by = s.id, payment_confirmed_at = now() where id = o.id;
    end if;
    update public.delivery_orders set status = 'entregue', delivered_at = now(), closed_at = now() where id = o.id;
  elsif p_action = 'cancelar' then
    if o.status in ('entregue','recusado','cancelado') then raise exception 'STATUS_INVALIDO'; end if;
    update public.delivery_orders set status = 'cancelado', reject_reason = left(coalesce(nullif(trim(p_extra->>'reason'),''),'Cancelado'),200), closed_at = now(), handled_by = s.id where id = o.id;
  else raise exception 'ACAO_INVALIDA';
  end if;
  perform public._event(s.establishment_id, null, s.id, 'delivery', s.name || ': delivery #' || o.number || ' ' || p_action, jsonb_build_object('order', o.id, 'action', p_action));
  return (select jsonb_build_object('status', status, 'payment_status', payment_status) from public.delivery_orders where id = o.id);
end $$;

create or replace function public.delivery_toggle(p_token uuid, p_open boolean) returns boolean
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_role(p_token, array['caixa','gerente']);
begin
  update public.establishments set delivery_open = p_open where id = s.establishment_id and plan = 'salao_delivery';
  if not found then raise exception 'PLANO_SEM_DELIVERY'; end if;
  perform public._event(s.establishment_id, null, s.id, 'delivery', s.name || case when p_open then ' abriu' else ' fechou' end || ' o delivery');
  return p_open;
end $$;

create or replace function public.owner_update_delivery(p jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare v_est uuid := public._owner_est(); v_type text := nullif(p->>'pix_key_type',''); v_key text := nullif(trim(coalesce(p->>'pix_key','')),''); d text;
begin
  if v_key is not null then
    d := regexp_replace(v_key, '\D', '', 'g');
    if v_type = 'cpf' then if length(d) <> 11 then raise exception 'PIX_INVALIDO'; end if; v_key := d;
    elsif v_type = 'cnpj' then if length(d) <> 14 then raise exception 'PIX_INVALIDO'; end if; v_key := d;
    elsif v_type = 'telefone' then if length(d) = 13 and left(d,2) = '55' then d := substr(d,3); end if; if length(d) not in (10,11) then raise exception 'PIX_INVALIDO'; end if; v_key := '+55' || d;
    elsif v_type = 'email' then if v_key !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'PIX_INVALIDO'; end if; v_key := lower(v_key);
    elsif v_type = 'aleatoria' then if v_key !~* '^[0-9a-f-]{32,36}$' then raise exception 'PIX_INVALIDO'; end if; v_key := lower(v_key);
    else raise exception 'PIX_INVALIDO'; end if;
  end if;
  update public.establishments set
    whatsapp = nullif(regexp_replace(coalesce(p->>'whatsapp',''), '\D', '', 'g'), ''),
    pix_key = v_key, pix_key_type = case when v_key is null then null else v_type end,
    pix_merchant_name = nullif(trim(coalesce(p->>'pix_merchant_name','')),''),
    pix_city = nullif(trim(coalesce(p->>'pix_city','')),''),
    delivery_fee_cents = greatest(0, coalesce((p->>'delivery_fee_cents')::int, 0)),
    min_order_cents = greatest(0, coalesce((p->>'min_order_cents')::int, 0)),
    delivery_eta_min = least(240, greatest(5, coalesce((p->>'delivery_eta_min')::int, 45)))
   where id = v_est;
  perform public._event(v_est, null, null, 'delivery', 'Dono alterou as configurações do delivery');
end $$;

-- relatório do dono passa a contar o delivery
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
     where ci.establishment_id = v_est and ci.created_at >= p_from and ci.created_at < p_to
    union all
    select di.product_id, di.name_snapshot, di.qty, di.qty * di.unit_price_cents, d.created_at, null::uuid
      from public.delivery_order_items di join public.delivery_orders d on d.id = di.delivery_order_id
     where di.establishment_id = v_est and d.status not in ('recusado','cancelado') and d.created_at >= p_from and d.created_at < p_to),
  prod as (select name_snapshot as name, sum(qty)::int as qty, sum(val)::int as total from sold group by name_snapshot)
  select jsonb_build_object(
    'revenue', (select coalesce(sum(amount_cents),0)::int from pay),
    'revenue_prev', (select coalesce(sum(amount_cents),0)::int from public.payments where establishment_id = v_est and created_at >= v_prev_from and created_at < p_from),
    'tables_closed', (select count(*)::int from closed),
    'people', (select coalesce(sum(people),0)::int from closed),
    'table_revenue', (select coalesce(sum(amount_cents),0)::int from pay where session_id is not null),
    'counter_count', (select count(*)::int from public.counter_sales where establishment_id = v_est and created_at >= p_from and created_at < p_to),
    'counter_revenue', (select coalesce(sum(amount_cents),0)::int from pay where counter_sale_id is not null),
    'delivery_count', (select count(*)::int from public.delivery_orders where establishment_id = v_est and status = 'entregue' and created_at >= p_from and created_at < p_to),
    'delivery_revenue', (select coalesce(sum(amount_cents),0)::int from pay where delivery_order_id is not null),
    'delivery_refused', (select count(*)::int from public.delivery_orders where establishment_id = v_est and status in ('recusado','cancelado') and created_at >= p_from and created_at < p_to),
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

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.public_menu(text) to anon, authenticated;
grant execute on function public.public_create_order(text, uuid, text, text, jsonb, jsonb, text, int, text) to anon, authenticated;
grant execute on function public.public_track(uuid) to anon, authenticated;
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
grant execute on function public.delivery_action(uuid, uuid, text, jsonb) to authenticated;
grant execute on function public.delivery_toggle(uuid, boolean) to authenticated;
grant execute on function public.owner_update_delivery(jsonb) to authenticated;
grant execute on function public.block_public_signup() to supabase_auth_admin;

alter publication supabase_realtime add table public.delivery_orders;

-- Cumbuca's no plano com delivery (teste)
update public.establishments set slug = 'cumbucas', plan = 'salao_delivery', delivery_open = true,
  delivery_fee_cents = 500, min_order_cents = 2000, delivery_eta_min = 45, pix_city = 'Cuiaba'
 where name = 'Cumbuca''s Bar';
