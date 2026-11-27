-- Delight Distributors offline transaction sync (run once in Supabase SQL Editor)
-- Adds idempotency keys so a queued transaction can safely retry after a timeout.

ALTER TABLE public.sales_orders
  ADD COLUMN IF NOT EXISTS client_transaction_id text;
ALTER TABLE public.payments
  ADD COLUMN IF NOT EXISTS client_transaction_id text;

CREATE UNIQUE INDEX IF NOT EXISTS sales_orders_client_transaction_id_uidx
  ON public.sales_orders(client_transaction_id)
  WHERE client_transaction_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS payments_client_transaction_id_uidx
  ON public.payments(client_transaction_id)
  WHERE client_transaction_id IS NOT NULL;

-- Idempotent wrapper around the existing sales-order transaction.
CREATE OR REPLACE FUNCTION public.dms_create_sales_order(
  p_retailer_id uuid,
  p_items jsonb,
  p_status text DEFAULT 'Pending',
  p_order_date date DEFAULT current_date,
  p_gst_enabled boolean DEFAULT false,
  p_gst_rate numeric DEFAULT 0,
  p_client_transaction_id text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE v_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_client_transaction_id IS NULL OR btrim(p_client_transaction_id)='' THEN
    RETURN public.dms_create_sales_order(p_retailer_id,p_items,p_status,p_order_date,p_gst_enabled,p_gst_rate);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_client_transaction_id,0));
  SELECT id INTO v_id FROM public.sales_orders WHERE client_transaction_id=p_client_transaction_id;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  v_id:=public.dms_create_sales_order(p_retailer_id,p_items,p_status,p_order_date,p_gst_enabled,p_gst_rate);
  UPDATE public.sales_orders SET client_transaction_id=p_client_transaction_id WHERE id=v_id;
  RETURN v_id;
END;
$$;

-- Idempotent wrapper around the existing payment transaction.
CREATE OR REPLACE FUNCTION public.dms_record_payment(
  p_party_type text,
  p_amount numeric,
  p_payment_mode text,
  p_retailer_id uuid DEFAULT NULL,
  p_supplier_id uuid DEFAULT NULL,
  p_reference_number text DEFAULT NULL,
  p_payment_date date DEFAULT current_date,
  p_client_transaction_id text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE v_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_client_transaction_id IS NULL OR btrim(p_client_transaction_id)='' THEN
    RETURN public.dms_record_payment(p_party_type,p_amount,p_payment_mode,p_retailer_id,p_supplier_id,p_reference_number,p_payment_date);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_client_transaction_id,0));
  SELECT id INTO v_id FROM public.payments WHERE client_transaction_id=p_client_transaction_id;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  v_id:=public.dms_record_payment(p_party_type,p_amount,p_payment_mode,p_retailer_id,p_supplier_id,p_reference_number,p_payment_date);
  UPDATE public.payments SET client_transaction_id=p_client_transaction_id WHERE id=v_id;
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.dms_create_sales_order(uuid,jsonb,text,date,boolean,numeric,text) FROM public,anon;
REVOKE ALL ON FUNCTION public.dms_record_payment(text,numeric,text,uuid,uuid,text,date,text) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.dms_create_sales_order(uuid,jsonb,text,date,boolean,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.dms_record_payment(text,numeric,text,uuid,uuid,text,date,text) TO authenticated;

NOTIFY pgrst, 'reload schema';
