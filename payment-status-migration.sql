-- Delight Distributors: sales-order payment status and partial-payment tracking
-- Run once in Supabase Dashboard > SQL Editor before using the new payment-status fields.

ALTER TABLE public.sales_orders
  ADD COLUMN IF NOT EXISTS payment_status text NOT NULL DEFAULT 'Credit',
  ADD COLUMN IF NOT EXISTS amount_paid numeric(12,2) NOT NULL DEFAULT 0;

-- Backfill existing orders using the previous Paid/Pending status.
UPDATE public.sales_orders
SET payment_status = CASE
  WHEN status = 'Paid' THEN 'Completed'
  WHEN status = 'Partially paid' THEN 'Partially paid'
  ELSE 'Credit'
END,
amount_paid = CASE
  WHEN status = 'Paid' THEN COALESCE(total_amount, 0)
  ELSE COALESCE(amount_paid, 0)
END
WHERE payment_status = 'Credit'
  AND amount_paid = 0
  AND status IN ('Paid', 'Pending', 'Partially paid');

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'sales_orders_payment_status_check'
      AND conrelid = 'public.sales_orders'::regclass
  ) THEN
    ALTER TABLE public.sales_orders
      ADD CONSTRAINT sales_orders_payment_status_check
      CHECK (payment_status IN ('Completed', 'Partially paid', 'Credit'));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'sales_orders_amount_paid_check'
      AND conrelid = 'public.sales_orders'::regclass
  ) THEN
    ALTER TABLE public.sales_orders
      ADD CONSTRAINT sales_orders_amount_paid_check
      CHECK (amount_paid >= 0 AND amount_paid <= COALESCE(total_amount, 0));
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
