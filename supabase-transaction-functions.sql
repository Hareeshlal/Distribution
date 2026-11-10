-- DistribuPro cloud transaction functions
-- Run this script in Supabase Dashboard > SQL Editor after the base schema setup.
-- Safe to run repeatedly: functions are created or replaced.

create or replace function public.dms_create_sales_order(
  p_retailer_id uuid,
  p_items jsonb,
  p_status text default 'Pending',
  p_order_date date default current_date
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id uuid;
  v_order_no text;
  v_total numeric(12,2) := 0;
  v_item jsonb;
  v_product_id uuid;
  v_qty integer;
  v_price numeric(12,2);
  v_stock integer;
  v_line numeric(12,2);
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_status not in ('Pending','Paid') then raise exception 'Invalid order status'; end if;
  if not exists(select 1 from public.retailers where id=p_retailer_id) then raise exception 'Retailer not found'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one order item'; end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;
    if v_qty is null or v_qty < 1 then raise exception 'Invalid item quantity'; end if;
    select stock_quantity, selling_price into v_stock, v_price
      from public.products where id=v_product_id for update;
    if not found then raise exception 'Product not found'; end if;
    if v_stock < v_qty then raise exception 'Insufficient stock for product %', v_product_id; end if;
    v_total := v_total + (v_price * v_qty);
  end loop;

  v_order_no := 'SO-' || to_char(clock_timestamp(),'YYYYMMDD-HH24MISSMS');
  insert into public.sales_orders(order_number,retailer_id,order_date,status,total_amount,created_by)
  values(v_order_no,p_retailer_id,p_order_date,p_status,v_total,auth.uid())
  returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;
    select selling_price into v_price from public.products where id=v_product_id;
    v_line := v_price * v_qty;
    insert into public.sales_order_items(order_id,product_id,quantity,unit_price,line_total)
    values(v_order_id,v_product_id,v_qty,v_price,v_line);
    update public.products set stock_quantity=stock_quantity-v_qty where id=v_product_id;
  end loop;

  insert into public.activity_logs(user_id,action,details)
  values(auth.uid(),'sales_order_created',jsonb_build_object('order_id',v_order_id,'order_number',v_order_no,'total',v_total));
  return v_order_id;
end;
$$;

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

