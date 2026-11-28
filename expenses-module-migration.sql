-- Delight Distributors: Expenses module
-- Run once in Supabase SQL Editor before using the Expenses tab.

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  expense_date date not null default current_date,
  category text not null check (category in ('Rent','EMI','Food allowance','Petrol','Daily wages','Other')),
  amount numeric(12,2) not null check (amount > 0),
  remarks text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists expenses_expense_date_idx on public.expenses(expense_date desc);
create index if not exists expenses_category_idx on public.expenses(category);

alter table public.expenses enable row level security;

drop policy if exists expenses_authenticated_all on public.expenses;
create policy expenses_authenticated_all on public.expenses
  for all to authenticated
  using (auth.uid() is not null)
  with check (auth.uid() is not null);

grant select, insert, update, delete on public.expenses to authenticated;
notify pgrst, 'reload schema';
