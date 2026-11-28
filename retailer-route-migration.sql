-- Add delivery route/area for retailers in Delight Distributors
alter table public.retailers
  add column if not exists route text;

notify pgrst, 'reload schema';
