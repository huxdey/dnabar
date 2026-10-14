-- DNBAR etapa 4: cardápio editável (dono e gerente), fotos, promoções e logo

alter table public.products add column if not exists description text;

-- imagens (logo e fotos do cardápio), uma pasta por bar
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', true, 3145728, array['image/png','image/jpeg','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 3145728, allowed_mime_types = array['image/png','image/jpeg','image/webp'];
create policy "dnbar envia imagem do proprio bar" on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = (select public.current_establishment_id())::text);
create policy "dnbar troca imagem do proprio bar" on storage.objects for update to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = (select public.current_establishment_id())::text);

-- promoções
create table public.promotions(
  id uuid primary key default gen_random_uuid(),
  establishment_id uuid not null references public.establishments(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  size_label text,
  promo_price_cents int not null check (promo_price_cents > 0),
  label text,
  kind text not null check (kind in ('periodo','happy')),
  starts_at timestamptz, ends_at timestamptz,
  weekdays int[], start_time time, end_time time,
  channel text not null default 'todos' check (channel in ('todos','salao','delivery')),
  active boolean not null default true,
  created_by uuid references public.staff(id),
  created_at timestamptz not null default now()
);
create index on public.promotions(establishment_id, active);
create index on public.promotions(product_id);
create index on public.promotions(created_by);
alter table public.promotions enable row level security;
create policy "ler promocoes" on public.promotions for select to authenticated using (establishment_id = (select public.current_establishment_id()));

-- preço que vale agora (base ou promoção), decidido pelo relógio do servidor
create or replace function public._price(p public.products, p_size text, p_channel text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_base int; v_promo int; v_label text; v_name text; v_tz text; v_now timestamp; v_size text := p_size;
begin
  if p.sizes is not null and jsonb_array_length(p.sizes) > 0 then
    select (x->>'v')::int into v_base from jsonb_array_elements(p.sizes) x where x->>'l' = v_size;
    if v_base is null then raise exception 'TAMANHO_INVALIDO:%', p.name; end if;
    v_name := p.name || ' (' || lower(v_size) || ')';
  else
    v_base := p.price_cents; v_size := null; v_name := p.name;
    if v_base is null then raise exception 'SEM_PRECO:%', p.name; end if;
  end if;
  select timezone into v_tz from public.establishments where id = p.establishment_id;
  v_now := now() at time zone coalesce(v_tz, 'America/Sao_Paulo');
  select r.promo_price_cents, r.label into v_promo, v_label from public.promotions r
   where r.product_id = p.id and r.active and (r.size_label is null or r.size_label = v_size)
     and r.channel in ('todos', p_channel)
     and (r.starts_at is null or now() >= r.starts_at) and (r.ends_at is null or now() < r.ends_at)
     and (r.weekdays is null or extract(dow from v_now)::int = any(r.weekdays))
     and (r.start_time is null or r.end_time is null or
          case when r.start_time <= r.end_time then v_now::time >= r.start_time and v_now::time < r.end_time
               else v_now::time >= r.start_time or v_now::time < r.end_time end)
   order by r.promo_price_cents limit 1;
  return jsonb_build_object('price', least(v_base, coalesce(v_promo, v_base)), 'base', v_base,
    'promo', coalesce(v_promo < v_base, false), 'label', v_label, 'name', v_name, 'size', v_size);
end $$;

create or replace function public._promos(p_est uuid, p_channel text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare p public.products; s jsonb; r jsonb; out jsonb := '[]'::jsonb;
begin
  for p in select pr.* from public.products pr where pr.establishment_id = p_est and pr.active
             and exists (select 1 from public.promotions x where x.product_id = pr.id and x.active) loop
    if p.sizes is not null and jsonb_array_length(p.sizes) > 0 then
      for s in select * from jsonb_array_elements(p.sizes) loop
        r := public._price(p, s->>'l', p_channel);
        if (r->>'promo')::boolean then out := out || jsonb_build_array(jsonb_build_object('product_id', p.id, 'size', s->>'l', 'price', r->'price', 'base', r->'base', 'label', r->'label')); end if;
      end loop;
    elsif p.price_cents is not null then
      r := public._price(p, null, p_channel);
      if (r->>'promo')::boolean then out := out || jsonb_build_array(jsonb_build_object('product_id', p.id, 'size', null, 'price', r->'price', 'base', r->'base', 'label', r->'label')); end if;
    end if;
  end loop;
  return out;
end $$;

create or replace function public.current_promos(p_channel text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select public._promos(public.current_establishment_id(), case when p_channel = 'delivery' then 'delivery' else 'salao' end)
$$;

-- ===== pedidos passam a usar _price (promoções valem automaticamente) =====
create or replace function public.create_order(p_token uuid, p_session_id uuid, p_key uuid, p_items jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s public.staff := public._staff_from_token(p_token);
  v_sess public.table_sessions; v_no int; v_oid uuid; it jsonb; p public.products; v_area text; pr jsonb;
  v_qty int; v_k int := 0; v_b int := 0; v_sum text;
begin
  select o.number into v_no from public.orders o where o.establishment_id = s.establishment_id and o.idempotency_key = p_key;
  if found then return jsonb_build_object('number', v_no, 'duplicate', true); end if;
  select * into v_sess from public.table_sessions where id = p_session_id and establishment_id = s.establishment_id and status = 'open' for update;
  if not found then raise exception 'MESA_FECHADA'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 50 then raise exception 'PEDIDO_VAZIO'; end if;
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
    pr := public._price(p, nullif(it->>'size',''), 'salao');
    v_qty := (it->>'qty')::int;
    if v_qty is null or v_qty < 1 or v_qty > 99 then raise exception 'QUANTIDADE_INVALIDA'; end if;
    insert into public.order_items(establishment_id, order_id, session_id, product_id, size_label, name_snapshot, unit_price_cents, qty, note, area)
    values (s.establishment_id, v_oid, p_session_id, p.id, pr->>'size', pr->>'name', (pr->>'price')::int, v_qty, left(nullif(trim(it->>'note'),''), 200), v_area);
    if v_area = 'bar' then v_b := v_b + v_qty; else v_k := v_k + v_qty; end if;
    v_sum := coalesce(v_sum || ', ', '') || v_qty || ' ' || (pr->>'name') || case when (pr->>'promo')::boolean then ' (promo)' else '' end;
  end loop;
  perform public._event(s.establishment_id, p_session_id, s.id, 'pedido', s.name || ' lançou pedido #' || v_no || ': ' || v_sum, jsonb_build_object('order_id', v_oid));
  return jsonb_build_object('number', v_no, 'cozinha', v_k, 'bar', v_b, 'duplicate', false);
end $$;

create or replace function public.counter_sale(p_token uuid, p_key uuid, p_items jsonb, p_method text, p_received_cents int default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.staff := public._staff_role(p_token, array['caixa','gerente']); v_cash uuid := public._open_cash(s.establishment_id);
  v_id uuid; v_no int; it jsonb; p public.products; pr jsonb; v_qty int; v_total int := 0; v_change int := 0; v_sum text;
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
    pr := public._price(p, nullif(it->>'size',''), 'salao');
    v_qty := (it->>'qty')::int;
    if v_qty is null or v_qty < 1 or v_qty > 99 then raise exception 'QUANTIDADE_INVALIDA'; end if;
    insert into public.counter_sale_items(establishment_id, sale_id, product_id, name_snapshot, unit_price_cents, qty)
    values (s.establishment_id, v_id, p.id, pr->>'name', (pr->>'price')::int, v_qty);
    v_total := v_total + (pr->>'price')::int * v_qty;
    v_sum := coalesce(v_sum || ', ', '') || v_qty || ' ' || (pr->>'name');
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

create or replace function public.public_create_order(p_slug text, p_key uuid, p_name text, p_phone text, p_address jsonb, p_items jsonb,
  p_method text, p_change_for_cents int default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare e public.establishments; v_id uuid; v_no int; v_tok uuid; it jsonb; p public.products; v_area text; pr jsonb; v_qty int;
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
    pr := public._price(p, nullif(it->>'size',''), 'delivery');
    v_qty := (it->>'qty')::int;
    if v_qty is null or v_qty < 1 or v_qty > 99 then raise exception 'QUANTIDADE_INVALIDA'; end if;
    insert into public.delivery_order_items(establishment_id, delivery_order_id, product_id, name_snapshot, size_label, unit_price_cents, qty, note, area)
    values (e.id, v_id, p.id, pr->>'name', pr->>'size', (pr->>'price')::int, v_qty, left(nullif(trim(coalesce(it->>'note','')),''),120), v_area);
    v_sub := v_sub + (pr->>'price')::int * v_qty;
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

create or replace function public.public_menu(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare e public.establishments;
begin
  select * into e from public.establishments where slug = lower(p_slug) and plan = 'salao_delivery';
  if not found then raise exception 'RESTAURANTE_NAO_ENCONTRADO'; end if;
  return jsonb_build_object('name', e.name, 'logo_url', e.logo_url, 'open', e.delivery_open, 'fee', e.delivery_fee_cents,
    'min', e.min_order_cents, 'eta', e.delivery_eta_min, 'whatsapp', e.whatsapp, 'pix', e.pix_key is not null,
    'promos', public._promos(e.id, 'delivery'),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'products', ps) order by c.sort), '[]'::jsonb)
      from public.categories c
      cross join lateral (select jsonb_agg(jsonb_build_object('id', p.id, 'number', p.number, 'name', p.name, 'description', p.description,
            'image_url', p.image_url, 'icon', p.icon, 'price', p.price_cents, 'sizes', p.sizes, 'available', p.available) order by p.sort) ps
          from public.products p where p.category_id = c.id and p.active and (p.price_cents is not null or (p.sizes is not null and jsonb_array_length(p.sizes) > 0))) x
      where c.establishment_id = e.id and c.active and ps is not null));
end $$;

-- ===== quem edita o cardápio: dono (conta própria) ou gerente (PIN no aparelho) =====
create or replace function public._catalog_actor(p_token uuid, p_owner_only boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.staff;
begin
  if p_token is not null then
    if p_owner_only then raise exception 'SEM_PERMISSAO'; end if;
    s := public._staff_role(p_token, array['gerente']);
    return jsonb_build_object('est', s.establishment_id, 'staff', s.id, 'name', s.name);
  end if;
  return jsonb_build_object('est', public._owner_est(), 'staff', null, 'name', 'Dono');
end $$;

create or replace function public._image_ok(p_est uuid, p_url text) returns boolean language sql immutable set search_path = '' as $$
  select p_url is null or p_url = '' or p_url ~ '^(img|logos)/[a-z0-9._-]+$'
      or p_url like 'https://omshldyfjethjufjhkrd.supabase.co/storage/v1/object/public/media/' || p_est::text || '/%'
$$;

create or replace function public.catalog_save_category(p_token uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare a jsonb := public._catalog_actor(p_token); v_est uuid := (a->>'est')::uuid; v_id uuid := nullif(p->>'id','')::uuid; v_name text := left(trim(coalesce(p->>'name','')),40);
begin
  if v_name = '' then raise exception 'NOME_INVALIDO'; end if;
  if coalesce(p->>'area','') not in ('cozinha','bar') then raise exception 'AREA_INVALIDA'; end if;
  if v_id is null then
    insert into public.categories(establishment_id, slug, name, area, sort, active)
    values (v_est, 'c' || substr(md5(gen_random_uuid()::text), 1, 10), v_name, p->>'area',
            coalesce((select max(sort) + 1 from public.categories where establishment_id = v_est), 0), true) returning id into v_id;
  else
    update public.categories set name = v_name, area = p->>'area', active = coalesce((p->>'active')::boolean, active),
      sort = coalesce((p->>'sort')::int, sort) where id = v_id and establishment_id = v_est;
    if not found then raise exception 'CATEGORIA_INVALIDA'; end if;
  end if;
  perform public._event(v_est, null, (a->>'staff')::uuid, 'cardapio', (a->>'name') || ' salvou a categoria ' || v_name, p);
  return v_id;
end $$;

create or replace function public.catalog_save_product(p_token uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare a jsonb := public._catalog_actor(p_token); v_est uuid := (a->>'est')::uuid; v_id uuid := nullif(p->>'id','')::uuid;
  v_name text := left(trim(coalesce(p->>'name','')),80); v_cat uuid := nullif(p->>'category_id','')::uuid; v_sizes jsonb; v_price int; v_num int; old public.products; s jsonb;
begin
  if v_name = '' then raise exception 'NOME_INVALIDO'; end if;
  perform 1 from public.categories where id = v_cat and establishment_id = v_est;
  if not found then raise exception 'CATEGORIA_INVALIDA'; end if;
  if jsonb_typeof(p->'sizes') = 'array' and jsonb_array_length(p->'sizes') > 0 then
    v_sizes := '[]'::jsonb;
    for s in select * from jsonb_array_elements(p->'sizes') loop
      if coalesce(trim(s->>'l'),'') = '' or (s->>'v')::int is null or (s->>'v')::int < 0 then raise exception 'VALOR_INVALIDO'; end if;
      v_sizes := v_sizes || jsonb_build_array(jsonb_build_object('l', left(trim(s->>'l'),20), 'v', (s->>'v')::int));
    end loop;
    v_price := null;
  else
    v_sizes := null; v_price := nullif(p->>'price_cents','')::int;
    if v_price is not null and v_price < 0 then raise exception 'VALOR_INVALIDO'; end if;
  end if;
  if not public._image_ok(v_est, p->>'image_url') then raise exception 'IMAGEM_INVALIDA'; end if;
  v_num := nullif(p->>'number','')::int;
  if v_id is null then
    if v_num is null then select coalesce(max(number), 0) + 1 into v_num from public.products where establishment_id = v_est; end if;
    begin
      insert into public.products(establishment_id, category_id, number, name, description, image_url, price_cents, sizes, available, active, sort)
      values (v_est, v_cat, v_num, v_name, left(nullif(trim(coalesce(p->>'description','')),''),200), nullif(p->>'image_url',''), v_price, v_sizes,
              coalesce((p->>'available')::boolean, true), true, coalesce((select max(sort) + 1 from public.products where category_id = v_cat), 0))
      returning id into v_id;
    exception when unique_violation then raise exception 'NUMERO_REPETIDO';
    end;
    perform public._event(v_est, null, (a->>'staff')::uuid, 'cardapio', (a->>'name') || ' criou o produto ' || v_name, p);
  else
    select * into old from public.products where id = v_id and establishment_id = v_est for update;
    if not found then raise exception 'PRODUTO_INVALIDO'; end if;
    begin
      update public.products set category_id = v_cat, number = coalesce(v_num, number), name = v_name,
        description = left(nullif(trim(coalesce(p->>'description','')),''),200), image_url = nullif(p->>'image_url',''),
        price_cents = v_price, sizes = v_sizes, available = coalesce((p->>'available')::boolean, available),
        active = coalesce((p->>'active')::boolean, active), updated_at = now()
       where id = v_id;
    exception when unique_violation then raise exception 'NUMERO_REPETIDO';
    end;
    perform public._event(v_est, null, (a->>'staff')::uuid, 'cardapio',
      (a->>'name') || case when (p->>'active')::boolean is false then ' removeu ' else ' alterou ' end || old.name
        || case when old.price_cents is distinct from v_price and v_price is not null then ' (preço ' || public._money(old.price_cents) || ' → ' || public._money(v_price) || ')' else '' end,
      jsonb_build_object('antes', to_jsonb(old) - 'establishment_id', 'depois', p));
  end if;
  return v_id;
end $$;

create or replace function public.promo_save(p_token uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare a jsonb := public._catalog_actor(p_token); v_est uuid := (a->>'est')::uuid; v_id uuid := nullif(p->>'id','')::uuid; pr public.products;
  v_size text := nullif(p->>'size_label',''); v_kind text := p->>'kind'; v_wd int[]; v_price int := (p->>'promo_price_cents')::int;
begin
  select * into pr from public.products where id = (p->>'product_id')::uuid and establishment_id = v_est and active;
  if not found then raise exception 'PRODUTO_INVALIDO'; end if;
  if v_size is not null and not exists (select 1 from jsonb_array_elements(coalesce(pr.sizes,'[]'::jsonb)) x where x->>'l' = v_size) then raise exception 'TAMANHO_INVALIDO'; end if;
  if v_price is null or v_price <= 0 then raise exception 'VALOR_INVALIDO'; end if;
  if coalesce(p->>'channel','todos') not in ('todos','salao','delivery') then raise exception 'VALOR_INVALIDO'; end if;
  if v_kind = 'periodo' then
    if nullif(p->>'starts_at','') is null or nullif(p->>'ends_at','') is null or (p->>'ends_at')::timestamptz <= (p->>'starts_at')::timestamptz then raise exception 'PERIODO_INVALIDO'; end if;
  elsif v_kind = 'happy' then
    select array_agg(x::int) into v_wd from jsonb_array_elements_text(coalesce(p->'weekdays','[]'::jsonb)) x where x::int between 0 and 6;
    if v_wd is null or nullif(p->>'start_time','') is null or nullif(p->>'end_time','') is null then raise exception 'PERIODO_INVALIDO'; end if;
  else raise exception 'VALOR_INVALIDO';
  end if;
  if v_id is null then
    insert into public.promotions(establishment_id, product_id, size_label, promo_price_cents, label, kind, starts_at, ends_at, weekdays, start_time, end_time, channel, created_by)
    values (v_est, pr.id, v_size, v_price, left(nullif(trim(coalesce(p->>'label','')),''),40), v_kind,
      case when v_kind = 'periodo' then (p->>'starts_at')::timestamptz end, case when v_kind = 'periodo' then (p->>'ends_at')::timestamptz end,
      case when v_kind = 'happy' then v_wd end, case when v_kind = 'happy' then (p->>'start_time')::time end, case when v_kind = 'happy' then (p->>'end_time')::time end,
      coalesce(p->>'channel','todos'), (a->>'staff')::uuid) returning id into v_id;
  else
    update public.promotions set product_id = pr.id, size_label = v_size, promo_price_cents = v_price, label = left(nullif(trim(coalesce(p->>'label','')),''),40), kind = v_kind,
      starts_at = case when v_kind = 'periodo' then (p->>'starts_at')::timestamptz end, ends_at = case when v_kind = 'periodo' then (p->>'ends_at')::timestamptz end,
      weekdays = case when v_kind = 'happy' then v_wd end, start_time = case when v_kind = 'happy' then (p->>'start_time')::time end, end_time = case when v_kind = 'happy' then (p->>'end_time')::time end,
      channel = coalesce(p->>'channel','todos'), active = coalesce((p->>'active')::boolean, active)
     where id = v_id and establishment_id = v_est;
    if not found then raise exception 'PROMO_INVALIDA'; end if;
  end if;
  perform public._event(v_est, null, (a->>'staff')::uuid, 'promocao', (a->>'name') || ' salvou promoção: ' || pr.name || coalesce(' (' || v_size || ')','') || ' por ' || public._money(v_price), p);
  return v_id;
end $$;

create or replace function public.promo_set_active(p_token uuid, p_id uuid, p_active boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare a jsonb := public._catalog_actor(p_token); v_est uuid := (a->>'est')::uuid;
begin
  update public.promotions set active = p_active where id = p_id and establishment_id = v_est;
  if not found then raise exception 'PROMO_INVALIDA'; end if;
  perform public._event(v_est, null, (a->>'staff')::uuid, 'promocao', (a->>'name') || case when p_active then ' ativou' else ' encerrou' end || ' uma promoção');
end $$;

create or replace function public.set_logo(p_url text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_est uuid := public._owner_est();
begin
  if not public._image_ok(v_est, p_url) then raise exception 'IMAGEM_INVALIDA'; end if;
  update public.establishments set logo_url = nullif(p_url,'') where id = v_est;
  perform public._event(v_est, null, null, 'marca', 'Dono alterou o logo');
end $$;

create or replace function public.catalog_history(p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a jsonb := public._catalog_actor(p_token); v_est uuid := (a->>'est')::uuid;
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('at', created_at, 'msg', message) order by id desc), '[]'::jsonb)
            from (select * from public.session_events where establishment_id = v_est and type in ('cardapio','promocao','produto','marca','delivery')
                    and session_id is null order by id desc limit 60) x);
end $$;

grant execute on function public.current_promos(text) to authenticated;
grant execute on function public.catalog_save_category(uuid, jsonb) to authenticated;
grant execute on function public.catalog_save_product(uuid, jsonb) to authenticated;
grant execute on function public.promo_save(uuid, jsonb) to authenticated;
grant execute on function public.promo_set_active(uuid, uuid, boolean) to authenticated;
grant execute on function public.set_logo(text) to authenticated;
grant execute on function public.catalog_history(uuid) to authenticated;
revoke execute on function public._price(public.products, text, text) from public, anon, authenticated;
revoke execute on function public._promos(uuid, text) from public, anon, authenticated;
revoke execute on function public._catalog_actor(uuid, boolean) from public, anon, authenticated;
revoke execute on function public._image_ok(uuid, text) from public, anon, authenticated;

alter publication supabase_realtime add table public.promotions;

update public.establishments set logo_url = 'logos/cumbucas.png' where slug = 'cumbucas';
