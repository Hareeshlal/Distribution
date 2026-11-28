-- Delight Distributors: route/date invoice numbering.
-- Run once in Supabase SQL Editor. Existing invoice numbers are not changed.
-- New format: INVDD + first two letters of retailer route + DDMM + 3-digit sequence.
-- Example: INVDDKM2811001

create table if not exists public.invoice_number_sequences (
  route_code text not null,
  invoice_date date not null,
  last_number integer not null default 0 check (last_number >= 0),
  primary key (route_code, invoice_date)
);

create or replace function public.dms_assign_invoice_number()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_route text;
  v_route_letters text;
  v_route_code text;
  v_sequence integer;
begin
  select route into v_route
  from public.retailers
  where id = new.retailer_id;

  v_route_letters := upper(left(regexp_replace(coalesce(v_route, ''), '[^A-Za-z]', '', 'g'), 2));

  if length(v_route_letters) < 2 then
    raise exception 'Please assign a route with at least two letters to this retailer before creating an invoice.';
  end if;

  v_route_code := v_route_letters;

  insert into public.invoice_number_sequences(route_code, invoice_date, last_number)
  values (v_route_code, new.order_date, 1)
  on conflict (route_code, invoice_date)
  do update set last_number = public.invoice_number_sequences.last_number + 1
  returning last_number into v_sequence;

  new.order_number := 'INVDD' || v_route_code ||
    to_char(new.order_date, 'DDMM') || lpad(v_sequence::text, 3, '0');

  return new;
end;
$$;

drop trigger if exists trg_dms_assign_invoice_number on public.sales_orders;
create trigger trg_dms_assign_invoice_number
before insert on public.sales_orders
for each row execute function public.dms_assign_invoice_number();

revoke all on function public.dms_assign_invoice_number() from public, anon, authenticated;
