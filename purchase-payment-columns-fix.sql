-- Fix purchase payment tracking fields used by the current Delight Distributors app.
-- Run once in Supabase SQL Editor.
alter table public.purchases
  add column if not exists payment_status text not null default 'Credit',
  add column if not exists amount_paid numeric(12,2) not null default 0;

-- Normalize existing rows without assuming old purchase payments were entered here.
update public.purchases
set payment_status = coalesce(nullif(payment_status,''),'Credit'),
    amount_paid = coalesce(amount_paid,0);

alter table public.purchases
  drop constraint if exists purchases_payment_status_check;
alter table public.purchases
  add constraint purchases_payment_status_check
  check (payment_status in ('Completed','Partially paid','Credit'));

alter table public.purchases
  drop constraint if exists purchases_amount_paid_check;
alter table public.purchases
  add constraint purchases_amount_paid_check
  check (amount_paid >= 0 and amount_paid <= total_amount);

notify pgrst, 'reload schema';
