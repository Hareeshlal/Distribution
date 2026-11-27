-- Delight Distributors: purchase-wise payment tracking
-- Run once in Supabase Dashboard > SQL Editor before using Purchase Payment Status.

ALTER TABLE public.purchases
  ADD COLUMN IF NOT EXISTS payment_status text NOT NULL DEFAULT 'Credit',
  ADD COLUMN IF NOT EXISTS amount_paid numeric(12,2) NOT NULL DEFAULT 0;

-- Existing purchase bills start as Credit because older supplier payments
-- were not allocated to individual purchase bills.
UPDATE public.purchases
SET payment_status = 'Credit',
    amount_paid = 0
WHERE payment_status IS NULL OR amount_paid IS NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'purchases_payment_status_check'
      AND conrelid = 'public.purchases'::regclass
  ) THEN
    ALTER TABLE public.purchases
      ADD CONSTRAINT purchases_payment_status_check
      CHECK (payment_status IN ('Completed', 'Partially paid', 'Credit'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'purchases_amount_paid_check'
      AND conrelid = 'public.purchases'::regclass
  ) THEN
    ALTER TABLE public.purchases
      ADD CONSTRAINT purchases_amount_paid_check
      CHECK (amount_paid >= 0 AND amount_paid <= COALESCE(total_amount, amount_paid));
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
