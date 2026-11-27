-- DistribuPro cloud transaction functions
-- Run this script in Supabase Dashboard > SQL Editor after the base schema setup.
-- Safe to run repeatedly: functions are created or replaced.

create or replace function public.dms_create_sales_order(
  p_retailer_id uuid,p_items jsonb,p_status text default 'Pending',
  p_order_date date default current_date,p_gst_enabled boolean default false,
  p_gst_rate numeric default 0
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  v_order_id uuid; v_order_no text; v_taxable numeric(12,2):=0;
  v_gst numeric(12,2):=0; v_total numeric(12,2):=0; v_item jsonb;
  v_product_id uuid; v_qty integer; v_price numeric(12,2); v_stock integer; v_line numeric(12,2);
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_status not in ('Pending','Paid') then raise exception 'Invalid order status'; end if;
  if not exists(select 1 from public.retailers where id=p_retailer_id) then raise exception 'Retailer not found'; end if;
  if p_gst_rate not in (0,5,12,18,28) then raise exception 'GST rate must be 0, 5, 12, 18 or 28'; end if;
  if not p_gst_enabled then p_gst_rate:=0; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one order item'; end if;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id:=(v_item->>'product_id')::uuid; v_qty:=(v_item->>'quantity')::integer;
    if v_qty is null or v_qty<1 then raise exception 'Invalid item quantity'; end if;
    select stock_quantity,selling_price into v_stock,v_price from public.products where id=v_product_id for update;
    if not found then raise exception 'Product not found'; end if;
    if v_item ? 'unit_price' then v_price:=(v_item->>'unit_price')::numeric; end if;
    if v_price is null or v_price<0 then raise exception 'Enter a valid unit selling rate'; end if;
    if v_stock<v_qty then raise exception 'Insufficient stock for product %',v_product_id; end if;
    v_taxable:=v_taxable+(v_price*v_qty);
  end loop;
  v_gst:=round(v_taxable*p_gst_rate/100,2); v_total:=v_taxable+v_gst;
  v_order_no:='SO-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISSMS');
  insert into public.sales_orders(order_number,retailer_id,order_date,status,total_amount,taxable_amount,gst_enabled,gst_rate,gst_amount,created_by)
  values(v_order_no,p_retailer_id,p_order_date,p_status,v_total,v_taxable,p_gst_enabled,p_gst_rate,v_gst,auth.uid())
  returning id into v_order_id;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id:=(v_item->>'product_id')::uuid; v_qty:=(v_item->>'quantity')::integer;
    select selling_price into v_price from public.products where id=v_product_id;
    if v_item ? 'unit_price' then v_price:=(v_item->>'unit_price')::numeric; end if;
    v_line:=v_price*v_qty;
    insert into public.sales_order_items(order_id,product_id,quantity,unit_price,line_total) values(v_order_id,v_product_id,v_qty,v_price,v_line);
    update public.products set stock_quantity=stock_quantity-v_qty where id=v_product_id;
  end loop;
  insert into public.activity_logs(user_id,action,details) values(auth.uid(),'sales_order_created',jsonb_build_object('order_id',v_order_id,'order_number',v_order_no,'taxable',v_taxable,'gst',v_gst,'total',v_total));
  return v_order_id;
end $$;

create or replace function public.dms_create_purchase(
  p_supplier_id uuid,
  p_items jsonb,
  p_purchase_date date default current_date,
  p_reference_number text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_purchase_id uuid;
  v_purchase_no text;
  v_total numeric(12,2) := 0;
  v_item jsonb;
  v_product_id uuid;
  v_qty integer;
  v_cost numeric(12,2);
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from public.suppliers where id=p_supplier_id) then raise exception 'Supplier not found'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one purchase item'; end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;
    v_cost := (v_item->>'unit_cost')::numeric;
    if v_qty is null or v_qty < 1 or v_cost is null or v_cost < 0 then raise exception 'Invalid purchase item'; end if;
    if not exists(select 1 from public.products where id=v_product_id) then raise exception 'Product not found'; end if;
    v_total := v_total + (v_cost*v_qty);
  end loop;

  v_purchase_no := 'PO-' || to_char(clock_timestamp(),'YYYYMMDD-HH24MISSMS');
  insert into public.purchases(purchase_number,supplier_id,purchase_date,reference_number,total_amount,created_by)
  values(v_purchase_no,p_supplier_id,p_purchase_date,p_reference_number,v_total,auth.uid())
  returning id into v_purchase_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;
    v_cost := (v_item->>'unit_cost')::numeric;
    insert into public.purchase_items(purchase_id,product_id,quantity,unit_cost,line_total)
    values(v_purchase_id,v_product_id,v_qty,v_cost,v_cost*v_qty);
    update public.products set stock_quantity=stock_quantity+v_qty where id=v_product_id;
  end loop;

  insert into public.activity_logs(user_id,action,details)
  values(auth.uid(),'purchase_created',jsonb_build_object('purchase_id',v_purchase_id,'purchase_number',v_purchase_no,'total',v_total));
  return v_purchase_id;
end;
$$;

create or replace function public.dms_record_payment(
  p_party_type text,
  p_amount numeric,
  p_payment_mode text,
  p_retailer_id uuid default null,
  p_supplier_id uuid default null,
  p_reference_number text default null,
  p_payment_date date default current_date
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_payment_id uuid; v_payment_no text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Payment amount must be positive'; end if;
  if p_party_type='retailer' then
    if p_retailer_id is null or p_supplier_id is not null or not exists(select 1 from public.retailers where id=p_retailer_id) then raise exception 'Select a valid retailer'; end if;
  elsif p_party_type='supplier' then
    if p_supplier_id is null or p_retailer_id is not null or not exists(select 1 from public.suppliers where id=p_supplier_id) then raise exception 'Select a valid supplier'; end if;
  else raise exception 'Invalid party type'; end if;
  if p_payment_mode not in ('Cash','UPI','Bank transfer','Cheque') then raise exception 'Invalid payment mode'; end if;
  v_payment_no := 'PAY-' || to_char(clock_timestamp(),'YYYYMMDD-HH24MISSMS');
  insert into public.payments(payment_number,party_type,retailer_id,supplier_id,amount,payment_mode,reference_number,payment_date,created_by)
  values(v_payment_no,p_party_type,p_retailer_id,p_supplier_id,p_amount,p_payment_mode,p_reference_number,p_payment_date,auth.uid())
  returning id into v_payment_id;
  insert into public.activity_logs(user_id,action,details)
  values(auth.uid(),'payment_recorded',jsonb_build_object('payment_id',v_payment_id,'payment_number',v_payment_no,'amount',p_amount,'party_type',p_party_type));
  return v_payment_id;
end;
$$;

revoke all on function public.dms_create_sales_order(uuid,jsonb,text,date) from public, anon;
revoke all on function public.dms_create_purchase(uuid,jsonb,date,text) from public, anon;
revoke all on function public.dms_record_payment(text,numeric,text,uuid,uuid,text,date) from public, anon;
grant execute on function public.dms_create_sales_order(uuid,jsonb,text,date) to authenticated;
grant execute on function public.dms_create_purchase(uuid,jsonb,date,text) to authenticated;
grant execute on function public.dms_record_payment(text,numeric,text,uuid,uuid,text,date) to authenticated;

-- Make activity history append-only for authenticated users.
drop policy if exists "Authenticated users manage activity logs" on public.activity_logs;
drop policy if exists "Users can manage activity logs" on public.activity_logs;
drop policy if exists "Authenticated users can view activity logs" on public.activity_logs;
drop policy if exists "Authenticated users can insert activity logs" on public.activity_logs;
create policy "Authenticated users can view activity logs"
on public.activity_logs for select to authenticated using (true);
create policy "Authenticated users can insert activity logs"
on public.activity_logs for insert to authenticated with check (user_id=auth.uid() or public.is_admin());

-- Safe deletion helpers used by the DistribuPro edit/delete controls.
-- Sales order deletion restores quantities to inventory in the same transaction.
create or replace function public.dms_delete_sales_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_order public.sales_orders%rowtype; v_item record;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_order from public.sales_orders where id=p_order_id for update;
  if not found then raise exception 'Sales order not found'; end if;
  for v_item in select product_id, quantity from public.sales_order_items where order_id=p_order_id
  loop
    update public.products set stock_quantity=stock_quantity+v_item.quantity where id=v_item.product_id;
  end loop;
  delete from public.sales_order_items where order_id=p_order_id;
  delete from public.sales_orders where id=p_order_id;
  insert into public.activity_logs(user_id,action,details)
  values(auth.uid(),'sales_order_deleted',jsonb_build_object('order_id',p_order_id,'order_number',v_order.order_number));
end;
$$;

-- Purchase deletion removes received quantities. Reject if stock has since been sold/used.
create or replace function public.dms_delete_purchase(p_purchase_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_purchase public.purchases%rowtype; v_item record; v_stock integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_purchase from public.purchases where id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  for v_item in select product_id, quantity from public.purchase_items where purchase_id=p_purchase_id
  loop
    select stock_quantity into v_stock from public.products where id=v_item.product_id for update;
    if v_stock < v_item.quantity then
      raise exception 'Cannot delete purchase: stock for product % is below received quantity',v_item.product_id;
    end if;
  end loop;
  for v_item in select product_id, quantity from public.purchase_items where purchase_id=p_purchase_id
  loop
    update public.products set stock_quantity=stock_quantity-v_item.quantity where id=v_item.product_id;
  end loop;
  delete from public.purchase_items where purchase_id=p_purchase_id;
  delete from public.purchases where id=p_purchase_id;
  insert into public.activity_logs(user_id,action,details)
  values(auth.uid(),'purchase_deleted',jsonb_build_object('purchase_id',p_purchase_id,'purchase_number',v_purchase.purchase_number));
end;
$$;

revoke all on function public.dms_delete_sales_order(uuid) from public, anon;
revoke all on function public.dms_delete_purchase(uuid) from public, anon;
grant execute on function public.dms_delete_sales_order(uuid) to authenticated;
grant execute on function public.dms_delete_purchase(uuid) to authenticated;

-- Update a sales order's single line item, retailer, date, or payment status atomically.
create or replace function public.dms_update_sales_order(
  p_order_id uuid,p_retailer_id uuid,p_product_id uuid,p_quantity integer,
  p_status text,p_order_date date
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare v_order public.sales_orders%rowtype; v_old record; v_stock integer; v_price numeric(12,2); v_total numeric(12,2);
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_quantity is null or p_quantity<1 then raise exception 'Quantity must be at least 1'; end if;
  if p_status not in ('Pending','Paid') then raise exception 'Invalid order status'; end if;
  if not exists(select 1 from public.retailers where id=p_retailer_id) then raise exception 'Retailer not found'; end if;
  select * into v_order from public.sales_orders where id=p_order_id for update;
  if not found then raise exception 'Sales order not found'; end if;
  for v_old in select product_id,quantity from public.sales_order_items where order_id=p_order_id
  loop update public.products set stock_quantity=stock_quantity+v_old.quantity where id=v_old.product_id; end loop;
  select stock_quantity,selling_price into v_stock,v_price from public.products where id=p_product_id for update;
  if not found then raise exception 'Product not found'; end if;
  if v_stock<p_quantity then raise exception 'Insufficient stock for selected product'; end if;
  v_total:=v_price*p_quantity;
  delete from public.sales_order_items where order_id=p_order_id;
  insert into public.sales_order_items(order_id,product_id,quantity,unit_price,line_total)
  values(p_order_id,p_product_id,p_quantity,v_price,v_total);
  update public.products set stock_quantity=stock_quantity-p_quantity where id=p_product_id;
  update public.sales_orders set retailer_id=p_retailer_id,order_date=p_order_date,status=p_status,total_amount=v_total where id=p_order_id;
  insert into public.activity_logs(user_id,action,details) values(auth.uid(),'sales_order_updated',jsonb_build_object('order_id',p_order_id,'total',v_total));
end;
$$;

-- Update a purchase's single line item and stock impact atomically.
create or replace function public.dms_update_purchase(
  p_purchase_id uuid,p_supplier_id uuid,p_product_id uuid,p_quantity integer,
  p_unit_cost numeric,p_purchase_date date,p_reference_number text
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare v_purchase public.purchases%rowtype; v_old record; v_stock integer; v_total numeric(12,2);
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_quantity is null or p_quantity<1 or p_unit_cost is null or p_unit_cost<0 then raise exception 'Enter a valid quantity and unit cost'; end if;
  if not exists(select 1 from public.suppliers where id=p_supplier_id) then raise exception 'Supplier not found'; end if;
  select * into v_purchase from public.purchases where id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  for v_old in select product_id,quantity from public.purchase_items where purchase_id=p_purchase_id
  loop
    select stock_quantity into v_stock from public.products where id=v_old.product_id for update;
    if v_stock<v_old.quantity then raise exception 'Cannot edit purchase: received stock for product % has already been used',v_old.product_id; end if;
    update public.products set stock_quantity=stock_quantity-v_old.quantity where id=v_old.product_id;
  end loop;
  select stock_quantity into v_stock from public.products where id=p_product_id for update;
  if not found then raise exception 'Product not found'; end if;
  if v_stock<0 then raise exception 'Cannot edit purchase: previous received stock has already been used'; end if;
  v_total:=p_quantity*p_unit_cost;
  delete from public.purchase_items where purchase_id=p_purchase_id;
  insert into public.purchase_items(purchase_id,product_id,quantity,unit_cost,line_total)
  values(p_purchase_id,p_product_id,p_quantity,p_unit_cost,v_total);
  update public.products set stock_quantity=stock_quantity+p_quantity where id=p_product_id;
  update public.purchases set supplier_id=p_supplier_id,purchase_date=p_purchase_date,reference_number=p_reference_number,total_amount=v_total where id=p_purchase_id;
  insert into public.activity_logs(user_id,action,details) values(auth.uid(),'purchase_updated',jsonb_build_object('purchase_id',p_purchase_id,'total',v_total));
end;
$$;

revoke all on function public.dms_update_sales_order(uuid,uuid,uuid,integer,text,date) from public,anon;
revoke all on function public.dms_update_purchase(uuid,uuid,uuid,integer,numeric,date,text) from public,anon;
grant execute on function public.dms_update_sales_order(uuid,uuid,uuid,integer,text,date) to authenticated;
grant execute on function public.dms_update_purchase(uuid,uuid,uuid,integer,numeric,date,text) to authenticated;


-- Delight Distributors GST support: taxable value, GST rate/amount, and inclusive grand total.
alter table public.sales_orders
  add column if not exists gst_enabled boolean not null default false,
  add column if not exists gst_rate numeric(5,2) not null default 0,
  add column if not exists taxable_amount numeric(12,2) not null default 0,
  add column if not exists gst_amount numeric(12,2) not null default 0;
alter table public.purchases
  add column if not exists gst_enabled boolean not null default false,
  add column if not exists gst_rate numeric(5,2) not null default 0,
  add column if not exists taxable_amount numeric(12,2) not null default 0,
  add column if not exists gst_amount numeric(12,2) not null default 0;

update public.sales_orders set taxable_amount=total_amount where taxable_amount=0 and total_amount<>0;
update public.purchases set taxable_amount=total_amount where taxable_amount=0 and total_amount<>0;

create or replace function public.dms_create_sales_order(
  p_retailer_id uuid,p_items jsonb,p_status text default 'Pending',
  p_order_date date default current_date,p_gst_enabled boolean default false,
  p_gst_rate numeric default 0
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  v_order_id uuid; v_order_no text; v_taxable numeric(12,2):=0;
  v_gst numeric(12,2):=0; v_total numeric(12,2):=0; v_item jsonb;
  v_product_id uuid; v_qty integer; v_price numeric(12,2); v_stock integer; v_line numeric(12,2);
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_status not in ('Pending','Paid') then raise exception 'Invalid order status'; end if;
  if not exists(select 1 from public.retailers where id=p_retailer_id) then raise exception 'Retailer not found'; end if;
  if p_gst_rate not in (0,5,12,18,28) then raise exception 'GST rate must be 0, 5, 12, 18 or 28'; end if;
  if not p_gst_enabled then p_gst_rate:=0; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one order item'; end if;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id:=(v_item->>'product_id')::uuid; v_qty:=(v_item->>'quantity')::integer;
    if v_qty is null or v_qty<1 then raise exception 'Invalid item quantity'; end if;
    select stock_quantity,selling_price into v_stock,v_price from public.products where id=v_product_id for update;
    if not found then raise exception 'Product not found'; end if;
    if v_stock<v_qty then raise exception 'Insufficient stock for product %',v_product_id; end if;
    v_taxable:=v_taxable+(v_price*v_qty);
  end loop;
  v_gst:=round(v_taxable*p_gst_rate/100,2); v_total:=v_taxable+v_gst;
  v_order_no:='SO-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISSMS');
  insert into public.sales_orders(order_number,retailer_id,order_date,status,total_amount,taxable_amount,gst_enabled,gst_rate,gst_amount,created_by)
  values(v_order_no,p_retailer_id,p_order_date,p_status,v_total,v_taxable,p_gst_enabled,p_gst_rate,v_gst,auth.uid())
  returning id into v_order_id;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id:=(v_item->>'product_id')::uuid; v_qty:=(v_item->>'quantity')::integer;
    select selling_price into v_price from public.products where id=v_product_id;
    v_line:=v_price*v_qty;
    insert into public.sales_order_items(order_id,product_id,quantity,unit_price,line_total) values(v_order_id,v_product_id,v_qty,v_price,v_line);
    update public.products set stock_quantity=stock_quantity-v_qty where id=v_product_id;
  end loop;
  insert into public.activity_logs(user_id,action,details) values(auth.uid(),'sales_order_created',jsonb_build_object('order_id',v_order_id,'order_number',v_order_no,'taxable',v_taxable,'gst',v_gst,'total',v_total));
  return v_order_id;
end $$;

create or replace function public.dms_create_purchase(
  p_supplier_id uuid,p_items jsonb,p_purchase_date date default current_date,
  p_reference_number text default null,p_gst_enabled boolean default false,
  p_gst_rate numeric default 0
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  v_purchase_id uuid; v_purchase_no text; v_taxable numeric(12,2):=0;
  v_gst numeric(12,2):=0; v_total numeric(12,2):=0; v_item jsonb;
  v_product_id uuid; v_qty integer; v_cost numeric(12,2);
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from public.suppliers where id=p_supplier_id) then raise exception 'Supplier not found'; end if;
  if p_gst_rate not in (0,5,12,18,28) then raise exception 'GST rate must be 0, 5, 12, 18 or 28'; end if;
  if not p_gst_enabled then p_gst_rate:=0; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one purchase item'; end if;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id:=(v_item->>'product_id')::uuid; v_qty:=(v_item->>'quantity')::integer; v_cost:=(v_item->>'unit_cost')::numeric;
    if v_qty is null or v_qty<1 or v_cost is null or v_cost<0 then raise exception 'Invalid purchase item'; end if;
    if not exists(select 1 from public.products where id=v_product_id) then raise exception 'Product not found'; end if;
    v_taxable:=v_taxable+(v_cost*v_qty);
  end loop;
  v_gst:=round(v_taxable*p_gst_rate/100,2); v_total:=v_taxable+v_gst;
  v_purchase_no:='PO-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISSMS');
  insert into public.purchases(purchase_number,supplier_id,purchase_date,reference_number,total_amount,taxable_amount,gst_enabled,gst_rate,gst_amount,created_by)
  values(v_purchase_no,p_supplier_id,p_purchase_date,p_reference_number,v_total,v_taxable,p_gst_enabled,p_gst_rate,v_gst,auth.uid())
  returning id into v_purchase_id;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id:=(v_item->>'product_id')::uuid; v_qty:=(v_item->>'quantity')::integer; v_cost:=(v_item->>'unit_cost')::numeric;
    insert into public.purchase_items(purchase_id,product_id,quantity,unit_cost,line_total) values(v_purchase_id,v_product_id,v_qty,v_cost,v_cost*v_qty);
    update public.products set stock_quantity=stock_quantity+v_qty where id=v_product_id;
  end loop;
  insert into public.activity_logs(user_id,action,details) values(auth.uid(),'purchase_created',jsonb_build_object('purchase_id',v_purchase_id,'purchase_number',v_purchase_no,'taxable',v_taxable,'gst',v_gst,'total',v_total));
  return v_purchase_id;
end $$;

revoke all on function public.dms_create_sales_order(uuid,jsonb,text,date,boolean,numeric) from public,anon;
revoke all on function public.dms_create_purchase(uuid,jsonb,date,text,boolean,numeric) from public,anon;
grant execute on function public.dms_create_sales_order(uuid,jsonb,text,date,boolean,numeric) to authenticated;
grant execute on function public.dms_create_purchase(uuid,jsonb,date,text,boolean,numeric) to authenticated;


-- GSTIN fields for retailer and supplier master records
ALTER TABLE public.retailers ADD COLUMN IF NOT EXISTS gst_number varchar(15);
ALTER TABLE public.suppliers ADD COLUMN IF NOT EXISTS gst_number varchar(15);


-- Product pack size: number of individual items contained in one SKU/box
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS units_per_sku integer NOT NULL DEFAULT 1;
ALTER TABLE public.products DROP CONSTRAINT IF EXISTS products_units_per_sku_positive;
ALTER TABLE public.products ADD CONSTRAINT products_units_per_sku_positive CHECK (units_per_sku >= 1);



-- FIFO inventory costing: one batch per purchase line, with GST-inclusive unit cost.
create table if not exists public.purchase_stock_batches (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete restrict,
  purchase_id uuid references public.purchases(id) on delete set null,
  purchase_item_id uuid references public.purchase_items(id) on delete set null,
  received_quantity integer not null check (received_quantity >= 0),
  remaining_quantity integer not null check (remaining_quantity >= 0 and remaining_quantity <= received_quantity),
  unit_cost_with_gst numeric(12,2) not null default 0,
  received_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists purchase_stock_batches_fifo_idx
  on public.purchase_stock_batches(product_id, received_at, created_at, id);
create table if not exists public.sales_order_item_fifo_allocations (
  id uuid primary key default gen_random_uuid(),
  sales_order_item_id uuid not null references public.sales_order_items(id) on delete cascade,
  batch_id uuid not null references public.purchase_stock_batches(id) on delete restrict,
  quantity integer not null check (quantity > 0),
  unit_cost_with_gst numeric(12,2) not null
);
create index if not exists sales_order_fifo_allocations_item_idx
  on public.sales_order_item_fifo_allocations(sales_order_item_id);

alter table public.purchase_stock_batches enable row level security;
alter table public.sales_order_item_fifo_allocations enable row level security;
drop policy if exists "Authenticated users view purchase stock batches" on public.purchase_stock_batches;
create policy "Authenticated users view purchase stock batches" on public.purchase_stock_batches
  for select to authenticated using (true);
drop policy if exists "Authenticated users view FIFO allocations" on public.sales_order_item_fifo_allocations;
create policy "Authenticated users view FIFO allocations" on public.sales_order_item_fifo_allocations
  for select to authenticated using (true);

-- Backfill historical purchases. FIFO-consumed quantities are removed from the oldest purchase batches.
with rows as (
  select pi.id purchase_item_id, pi.purchase_id, pi.product_id, pi.quantity,
         greatest(0,round(pi.unit_cost * (1 + coalesce(p.gst_rate,0)/100),2)) gross_cost,
         (coalesce(p.purchase_date, p.created_at::date)::timestamp at time zone 'UTC') received_at,
         coalesce(sum(pi.quantity) over (
           partition by pi.product_id
           order by coalesce(p.purchase_date,p.created_at::date), p.created_at, pi.id
           rows between unbounded preceding and 1 preceding),0) prior_qty,
         sum(pi.quantity) over (partition by pi.product_id) total_purchased,
         pr.stock_quantity
  from public.purchase_items pi
  join public.purchases p on p.id=pi.purchase_id
  join public.products pr on pr.id=pi.product_id
), remaining as (
  select *, greatest(0, quantity - greatest(0,least(quantity, (total_purchased-stock_quantity)-prior_qty))) rem
  from rows
)
insert into public.purchase_stock_batches(product_id,purchase_id,purchase_item_id,received_quantity,remaining_quantity,unit_cost_with_gst,received_at)
select product_id,purchase_id,purchase_item_id,quantity,rem,gross_cost,received_at
from remaining
where rem>0
and not exists(select 1 from public.purchase_stock_batches b where b.purchase_item_id=remaining.purchase_item_id);

-- Preserve any opening/adjusted stock that was not represented by historical purchase lines.
insert into public.purchase_stock_batches(product_id,received_quantity,remaining_quantity,unit_cost_with_gst,received_at)
select pr.id, greatest(0,pr.stock_quantity-coalesce(sum(pi.quantity),0)),
       greatest(0,pr.stock_quantity-coalesce(sum(pi.quantity),0)),
       coalesce(pr.purchase_price,0), '1900-01-01'::timestamptz
from public.products pr left join public.purchase_items pi on pi.product_id=pr.id
group by pr.id,pr.stock_quantity,pr.purchase_price
having pr.stock_quantity>coalesce(sum(pi.quantity),0)
and not exists(select 1 from public.purchase_stock_batches b where b.product_id=pr.id and b.purchase_id is null);

-- New purchases create an immutable cost batch and refresh the product's displayed FIFO/current cost.
create or replace function public.dms_create_purchase(
  p_supplier_id uuid,p_items jsonb,p_purchase_date date default current_date,
  p_reference_number text default null,p_gst_enabled boolean default false,p_gst_rate numeric default 0
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  v_purchase_id uuid; v_purchase_no text; v_taxable numeric(12,2):=0;
  v_gst numeric(12,2):=0; v_total numeric(12,2):=0; v_item jsonb;
  v_product_id uuid; v_qty integer; v_cost numeric(12,4); v_gross numeric(12,2);
  v_item_id uuid; v_ordered_at timestamptz;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from public.suppliers where id=p_supplier_id) then raise exception 'Supplier not found'; end if;
  if p_gst_rate not in (0,5,12,18,28) then raise exception 'GST rate must be 0, 5, 12, 18 or 28'; end if;
  if not p_gst_enabled then p_gst_rate:=0; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one purchase item'; end if;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id:=(v_item->>'product_id')::uuid; v_qty:=(v_item->>'quantity')::integer;
    v_cost:=(v_item->>'unit_cost')::numeric;
    if v_qty is null or v_qty<1 or v_cost is null or v_cost<0 then raise exception 'Invalid purchase item'; end if;
    if not exists(select 1 from public.products where id=v_product_id) then raise exception 'Product not found'; end if;
    v_taxable:=v_taxable+(v_cost*v_qty);
  end loop;
  v_gst:=round(v_taxable*p_gst_rate/100,2); v_total:=v_taxable+v_gst;
  v_purchase_no:='PO-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISSMS');
  insert into public.purchases(purchase_number,supplier_id,purchase_date,reference_number,total_amount,taxable_amount,gst_enabled,gst_rate,gst_amount,created_by)
  values(v_purchase_no,p_supplier_id,p_purchase_date,p_reference_number,v_total,v_taxable,p_gst_enabled,p_gst_rate,v_gst,auth.uid())
  returning id,created_at into v_purchase_id,v_ordered_at;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id:=(v_item->>'product_id')::uuid; v_qty:=(v_item->>'quantity')::integer; v_cost:=(v_item->>'unit_cost')::numeric;
    v_gross:=round(v_cost*(1+p_gst_rate/100),2);
    insert into public.purchase_items(purchase_id,product_id,quantity,unit_cost,line_total)
    values(v_purchase_id,v_product_id,v_qty,v_cost,v_cost*v_qty) returning id into v_item_id;
    insert into public.purchase_stock_batches(product_id,purchase_id,purchase_item_id,received_quantity,remaining_quantity,unit_cost_with_gst,received_at)
    values(v_product_id,v_purchase_id,v_item_id,v_qty,v_qty,v_gross,(p_purchase_date::timestamp at time zone 'UTC'));
    update public.products set stock_quantity=stock_quantity+v_qty,purchase_price=v_gross where id=v_product_id;
  end loop;
  insert into public.activity_logs(user_id,action,details)
  values(auth.uid(),'purchase_created',jsonb_build_object('purchase_id',v_purchase_id,'purchase_number',v_purchase_no,'taxable',v_taxable,'gst',v_gst,'total',v_total));
  return v_purchase_id;
end $$;

-- Sales deduct stock from the oldest available cost batch and save the FIFO cost allocation.
create or replace function public.dms_create_sales_order(
  p_retailer_id uuid,p_items jsonb,p_status text default 'Pending',
  p_order_date date default current_date,p_gst_enabled boolean default false,p_gst_rate numeric default 0
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  v_order_id uuid; v_order_no text; v_taxable numeric(12,2):=0; v_gst numeric(12,2):=0;
  v_total numeric(12,2):=0; v_item jsonb; v_product_id uuid; v_qty integer;
  v_price numeric(12,2); v_stock integer; v_line numeric(12,2); v_so_item_id uuid;
  v_batch record; v_take integer; v_remaining integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_status not in ('Pending','Paid') then raise exception 'Invalid order status'; end if;
  if not exists(select 1 from public.retailers where id=p_retailer_id) then raise exception 'Retailer not found'; end if;
  if p_gst_rate not in (0,5,12,18,28) then raise exception 'GST rate must be 0, 5, 12, 18 or 28'; end if;
  if not p_gst_enabled then p_gst_rate:=0; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one order item'; end if;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id:=(v_item->>'product_id')::uuid; v_qty:=(v_item->>'quantity')::integer;
    if v_qty is null or v_qty<1 then raise exception 'Invalid item quantity'; end if;
    select stock_quantity,selling_price into v_stock,v_price from public.products where id=v_product_id for update;
    if not found then raise exception 'Product not found'; end if;
    if v_item ? 'unit_price' then v_price:=(v_item->>'unit_price')::numeric; end if;
    if v_price is null or v_price<0 then raise exception 'Enter a valid unit selling rate'; end if;
    if v_stock<v_qty then raise exception 'Insufficient stock for product %',v_product_id; end if;
    v_taxable:=v_taxable+(v_price*v_qty);
  end loop;
  v_gst:=round(v_taxable*p_gst_rate/100,2); v_total:=v_taxable+v_gst;
  v_order_no:='SO-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISSMS');
  insert into public.sales_orders(order_number,retailer_id,order_date,status,total_amount,taxable_amount,gst_enabled,gst_rate,gst_amount,created_by)
  values(v_order_no,p_retailer_id,p_order_date,p_status,v_total,v_taxable,p_gst_enabled,p_gst_rate,v_gst,auth.uid())
  returning id into v_order_id;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id:=(v_item->>'product_id')::uuid; v_qty:=(v_item->>'quantity')::integer;
    select selling_price into v_price from public.products where id=v_product_id;
    if v_item ? 'unit_price' then v_price:=(v_item->>'unit_price')::numeric; end if;
    v_line:=v_price*v_qty;
    insert into public.sales_order_items(order_id,product_id,quantity,unit_price,line_total)
    values(v_order_id,v_product_id,v_qty,v_price,v_line) returning id into v_so_item_id;
    v_remaining:=v_qty;
    for v_batch in select id,remaining_quantity,unit_cost_with_gst from public.purchase_stock_batches
      where product_id=v_product_id and remaining_quantity>0
      order by received_at,created_at,id for update
    loop
      exit when v_remaining<=0;
      v_take:=least(v_remaining,v_batch.remaining_quantity);
      update public.purchase_stock_batches set remaining_quantity=remaining_quantity-v_take where id=v_batch.id;
      insert into public.sales_order_item_fifo_allocations(sales_order_item_id,batch_id,quantity,unit_cost_with_gst)
      values(v_so_item_id,v_batch.id,v_take,v_batch.unit_cost_with_gst);
      v_remaining:=v_remaining-v_take;
    end loop;
    if v_remaining>0 then raise exception 'FIFO batch stock is short for product %; refresh stock batches before selling',v_product_id; end if;
    update public.products set stock_quantity=stock_quantity-v_qty where id=v_product_id;
  end loop;
  insert into public.activity_logs(user_id,action,details)
  values(auth.uid(),'sales_order_created',jsonb_build_object('order_id',v_order_id,'order_number',v_order_no,'taxable',v_taxable,'gst',v_gst,'total',v_total));
  return v_order_id;
end $$;

-- Deleting a sale restores the exact FIFO batches used by that order.
create or replace function public.dms_delete_sales_order(p_order_id uuid)
returns void language plpgsql security definer set search_path=public
as $$
declare v_order public.sales_orders%rowtype; v_item record; v_alloc record;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_order from public.sales_orders where id=p_order_id for update;
  if not found then raise exception 'Sales order not found'; end if;
  for v_item in select id,product_id,quantity from public.sales_order_items where order_id=p_order_id loop
    if exists(select 1 from public.sales_order_item_fifo_allocations where sales_order_item_id=v_item.id) then
      for v_alloc in select batch_id,quantity from public.sales_order_item_fifo_allocations where sales_order_item_id=v_item.id loop
        update public.purchase_stock_batches set remaining_quantity=least(received_quantity,remaining_quantity+v_alloc.quantity) where id=v_alloc.batch_id;
      end loop;
    else
      -- Older sales created before FIFO migration: restore stock as a dated opening batch.
      insert into public.purchase_stock_batches(product_id,received_quantity,remaining_quantity,unit_cost_with_gst,received_at)
      select v_item.product_id,v_item.quantity,v_item.quantity,coalesce(p.purchase_price,0),now()
      from public.products p where p.id=v_item.product_id;
    end if;
    update public.products set stock_quantity=stock_quantity+v_item.quantity where id=v_item.product_id;
  end loop;
  delete from public.sales_order_items where order_id=p_order_id;
  delete from public.sales_orders where id=p_order_id;
  insert into public.activity_logs(user_id,action,details)
  values(auth.uid(),'sales_order_deleted',jsonb_build_object('order_id',p_order_id,'order_number',v_order.order_number));
end $$;

-- Purchase deletion is permitted only if its batch has not been consumed.
create or replace function public.dms_delete_purchase(p_purchase_id uuid)
returns void language plpgsql security definer set search_path=public
as $$
declare v_purchase public.purchases%rowtype; v_item record; v_batch record;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_purchase from public.purchases where id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  for v_item in select id,product_id,quantity from public.purchase_items where purchase_id=p_purchase_id loop
    select * into v_batch from public.purchase_stock_batches where purchase_item_id=v_item.id for update;
    if found and v_batch.remaining_quantity<v_batch.received_quantity then
      raise exception 'Cannot delete purchase: FIFO stock from this purchase has already been sold or used';
    end if;
  end loop;
  for v_item in select product_id,quantity from public.purchase_items where purchase_id=p_purchase_id loop
    update public.products set stock_quantity=stock_quantity-v_item.quantity where id=v_item.product_id;
  end loop;
  delete from public.purchase_items where purchase_id=p_purchase_id;
  delete from public.purchases where id=p_purchase_id;
  delete from public.purchase_stock_batches where purchase_id=p_purchase_id;
  insert into public.activity_logs(user_id,action,details)
  values(auth.uid(),'purchase_deleted',jsonb_build_object('purchase_id',p_purchase_id,'purchase_number',v_purchase.purchase_number));
end $$;

revoke all on function public.dms_create_sales_order(uuid,jsonb,text,date,boolean,numeric) from public,anon;
revoke all on function public.dms_create_purchase(uuid,jsonb,date,text,boolean,numeric) from public,anon;
revoke all on function public.dms_delete_sales_order(uuid) from public,anon;
revoke all on function public.dms_delete_purchase(uuid) from public,anon;
grant execute on function public.dms_create_sales_order(uuid,jsonb,text,date,boolean,numeric) to authenticated;
grant execute on function public.dms_create_purchase(uuid,jsonb,date,text,boolean,numeric) to authenticated;
grant execute on function public.dms_delete_sales_order(uuid) to authenticated;
grant execute on function public.dms_delete_purchase(uuid) to authenticated;
