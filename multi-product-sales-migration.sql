-- Multi-product sales orders with per-line GST.
-- Run once in Supabase SQL Editor before creating multi-product orders.
alter table public.sales_order_items
  add column if not exists gst_rate numeric(5,2),
  add column if not exists gst_amount numeric(12,2);

create or replace function public.dms_create_sales_order(
  p_retailer_id uuid,p_items jsonb,p_status text default 'Pending',
  p_order_date date default current_date,p_gst_enabled boolean default false,
  p_gst_rate numeric default 0
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  v_order_id uuid; v_order_no text; v_taxable numeric(12,2):=0; v_gst numeric(12,2):=0;
  v_total numeric(12,2):=0; v_item jsonb; v_product_id uuid; v_qty integer;
  v_price numeric(12,2); v_stock integer; v_line numeric(12,2); v_line_gst numeric(12,2);
  v_rate numeric(5,2); v_so_item_id uuid; v_batch record; v_take integer; v_remaining integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_status not in ('Pending','Paid') then raise exception 'Invalid order status'; end if;
  if not exists(select 1 from public.retailers where id=p_retailer_id) then raise exception 'Retailer not found'; end if;
  if p_gst_rate not in (0,5,12,18,28) then raise exception 'GST rate must be 0, 5, 12, 18 or 28'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one order item'; end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id:=(v_item->>'product_id')::uuid; v_qty:=(v_item->>'quantity')::integer;
    select stock_quantity,selling_price into v_stock,v_price from public.products where id=v_product_id for update;
    if not found then raise exception 'Product not found'; end if;
    if v_qty is null or v_qty<1 then raise exception 'Invalid item quantity'; end if;
    if v_item ? 'unit_price' then v_price:=(v_item->>'unit_price')::numeric; end if;
    if v_price is null or v_price<0 then raise exception 'Enter a valid unit selling rate'; end if;
    v_rate:=case when v_item ? 'gst_rate' then (v_item->>'gst_rate')::numeric else p_gst_rate end;
    if not p_gst_enabled then v_rate:=0; end if;
    if v_rate not in (0,5,12,18,28) then raise exception 'GST rate must be 0, 5, 12, 18 or 28'; end if;
    if v_stock<v_qty then raise exception 'Insufficient stock for product %',v_product_id; end if;
    v_line:=round(v_price*v_qty,2); v_line_gst:=round(v_line*v_rate/100,2);
    v_taxable:=v_taxable+v_line; v_gst:=v_gst+v_line_gst;
  end loop;

  v_total:=v_taxable+v_gst;
  v_order_no:='SO-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISSMS');
  insert into public.sales_orders(order_number,retailer_id,order_date,status,total_amount,taxable_amount,gst_enabled,gst_rate,gst_amount,created_by)
  values(v_order_no,p_retailer_id,p_order_date,p_status,v_total,v_taxable,p_gst_enabled,p_gst_rate,v_gst,auth.uid())
  returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id:=(v_item->>'product_id')::uuid; v_qty:=(v_item->>'quantity')::integer;
    select selling_price into v_price from public.products where id=v_product_id;
    if v_item ? 'unit_price' then v_price:=(v_item->>'unit_price')::numeric; end if;
    v_rate:=case when v_item ? 'gst_rate' then (v_item->>'gst_rate')::numeric else p_gst_rate end;
    if not p_gst_enabled then v_rate:=0; end if;
    v_line:=round(v_price*v_qty,2); v_line_gst:=round(v_line*v_rate/100,2);
    insert into public.sales_order_items(order_id,product_id,quantity,unit_price,line_total,gst_rate,gst_amount)
    values(v_order_id,v_product_id,v_qty,v_price,v_line,v_rate,v_line_gst) returning id into v_so_item_id;

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

revoke all on function public.dms_create_sales_order(uuid,jsonb,text,date,boolean,numeric) from public,anon;
grant execute on function public.dms_create_sales_order(uuid,jsonb,text,date,boolean,numeric) to authenticated;
