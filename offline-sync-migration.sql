-- Delight Distributors offline transaction sync. Run once in Supabase SQL Editor.
ALTER TABLE public.sales_orders ADD COLUMN IF NOT EXISTS client_transaction_id text;
ALTER TABLE public.payments ADD COLUMN IF NOT EXISTS client_transaction_id text;
CREATE UNIQUE INDEX IF NOT EXISTS sales_orders_client_transaction_id_uidx ON public.sales_orders(client_transaction_id) WHERE client_transaction_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS payments_client_transaction_id_uidx ON public.payments(client_transaction_id) WHERE client_transaction_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.dms_create_sales_order(
 p_retailer_id uuid,p_items jsonb,p_status text DEFAULT 'Pending',p_order_date date DEFAULT current_date,
 p_gst_enabled boolean DEFAULT false,p_gst_rate numeric DEFAULT 0,p_client_transaction_id text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_order_id uuid;v_order_no text;v_taxable numeric(12,2):=0;v_gst numeric(12,2):=0;v_total numeric(12,2):=0;v_item jsonb;v_product_id uuid;v_qty integer;v_price numeric(12,2);v_stock integer;v_line numeric(12,2);
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
 IF p_client_transaction_id IS NOT NULL AND btrim(p_client_transaction_id)<>'' THEN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_client_transaction_id,0));
  SELECT id INTO v_order_id FROM public.sales_orders WHERE client_transaction_id=p_client_transaction_id;
  IF v_order_id IS NOT NULL THEN RETURN v_order_id; END IF;
 END IF;
 IF p_status NOT IN ('Pending','Paid') THEN RAISE EXCEPTION 'Invalid order status'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.retailers WHERE id=p_retailer_id) THEN RAISE EXCEPTION 'Retailer not found'; END IF;
 IF p_gst_rate NOT IN (0,5,12,18,28) THEN RAISE EXCEPTION 'GST rate must be 0, 5, 12, 18 or 28'; END IF;
 IF NOT p_gst_enabled THEN p_gst_rate:=0; END IF;
 IF jsonb_typeof(p_items)<>'array' OR jsonb_array_length(p_items)=0 THEN RAISE EXCEPTION 'Add at least one order item'; END IF;
 FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
  v_product_id:=(v_item->>'product_id')::uuid;v_qty:=(v_item->>'quantity')::integer;
  IF v_qty IS NULL OR v_qty<1 THEN RAISE EXCEPTION 'Invalid item quantity'; END IF;
  SELECT stock_quantity,selling_price INTO v_stock,v_price FROM public.products WHERE id=v_product_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Product not found'; END IF;
  IF v_item ? 'unit_price' THEN v_price:=(v_item->>'unit_price')::numeric; END IF;
  IF v_price IS NULL OR v_price<0 THEN RAISE EXCEPTION 'Enter a valid unit selling rate'; END IF;
  IF v_stock<v_qty THEN RAISE EXCEPTION 'Insufficient stock for product %',v_product_id; END IF;
  v_taxable:=v_taxable+(v_price*v_qty);
 END LOOP;
 v_gst:=round(v_taxable*p_gst_rate/100,2);v_total:=v_taxable+v_gst;
 v_order_no:='SO-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISSMS');
 INSERT INTO public.sales_orders(order_number,retailer_id,order_date,status,total_amount,taxable_amount,gst_enabled,gst_rate,gst_amount,created_by,client_transaction_id)
 VALUES(v_order_no,p_retailer_id,p_order_date,p_status,v_total,v_taxable,p_gst_enabled,p_gst_rate,v_gst,auth.uid(),NULLIF(btrim(p_client_transaction_id),'')) RETURNING id INTO v_order_id;
 FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
  v_product_id:=(v_item->>'product_id')::uuid;v_qty:=(v_item->>'quantity')::integer;SELECT selling_price INTO v_price FROM public.products WHERE id=v_product_id;
  IF v_item ? 'unit_price' THEN v_price:=(v_item->>'unit_price')::numeric; END IF;v_line:=v_price*v_qty;
  INSERT INTO public.sales_order_items(order_id,product_id,quantity,unit_price,line_total) VALUES(v_order_id,v_product_id,v_qty,v_price,v_line);
  UPDATE public.products SET stock_quantity=stock_quantity-v_qty WHERE id=v_product_id;
 END LOOP;
 INSERT INTO public.activity_logs(user_id,action,details) VALUES(auth.uid(),'sales_order_created',jsonb_build_object('order_id',v_order_id,'order_number',v_order_no,'taxable',v_taxable,'gst',v_gst,'total',v_total));
 RETURN v_order_id;
END $$;

CREATE OR REPLACE FUNCTION public.dms_record_payment(
 p_party_type text,p_amount numeric,p_payment_mode text,p_retailer_id uuid DEFAULT NULL,p_supplier_id uuid DEFAULT NULL,
 p_reference_number text DEFAULT NULL,p_payment_date date DEFAULT current_date,p_client_transaction_id text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_payment_id uuid;v_payment_no text;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
 IF p_client_transaction_id IS NOT NULL AND btrim(p_client_transaction_id)<>'' THEN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_client_transaction_id,0));
  SELECT id INTO v_payment_id FROM public.payments WHERE client_transaction_id=p_client_transaction_id;
  IF v_payment_id IS NOT NULL THEN RETURN v_payment_id; END IF;
 END IF;
 IF p_amount IS NULL OR p_amount<=0 THEN RAISE EXCEPTION 'Payment amount must be positive'; END IF;
 IF p_party_type='retailer' THEN
  IF p_retailer_id IS NULL OR p_supplier_id IS NOT NULL OR NOT EXISTS(SELECT 1 FROM public.retailers WHERE id=p_retailer_id) THEN RAISE EXCEPTION 'Select a valid retailer'; END IF;
 ELSIF p_party_type='supplier' THEN
  IF p_supplier_id IS NULL OR p_retailer_id IS NOT NULL OR NOT EXISTS(SELECT 1 FROM public.suppliers WHERE id=p_supplier_id) THEN RAISE EXCEPTION 'Select a valid supplier'; END IF;
 ELSE RAISE EXCEPTION 'Invalid party type'; END IF;
 IF p_payment_mode NOT IN ('Cash','UPI','Bank transfer','Cheque') THEN RAISE EXCEPTION 'Invalid payment mode'; END IF;
 v_payment_no:='PAY-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISSMS');
 INSERT INTO public.payments(payment_number,party_type,retailer_id,supplier_id,amount,payment_mode,reference_number,payment_date,created_by,client_transaction_id)
 VALUES(v_payment_no,p_party_type,p_retailer_id,p_supplier_id,p_amount,p_payment_mode,p_reference_number,p_payment_date,auth.uid(),NULLIF(btrim(p_client_transaction_id),'')) RETURNING id INTO v_payment_id;
 INSERT INTO public.activity_logs(user_id,action,details) VALUES(auth.uid(),'payment_recorded',jsonb_build_object('payment_id',v_payment_id,'payment_number',v_payment_no,'amount',p_amount,'party_type',p_party_type));
 RETURN v_payment_id;
END $$;

DROP FUNCTION IF EXISTS public.dms_create_sales_order(uuid,jsonb,text,date,boolean,numeric);
DROP FUNCTION IF EXISTS public.dms_record_payment(text,numeric,text,uuid,uuid,text,date);
REVOKE ALL ON FUNCTION public.dms_create_sales_order(uuid,jsonb,text,date,boolean,numeric,text) FROM public,anon;
REVOKE ALL ON FUNCTION public.dms_record_payment(text,numeric,text,uuid,uuid,text,date,text) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.dms_create_sales_order(uuid,jsonb,text,date,boolean,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.dms_record_payment(text,numeric,text,uuid,uuid,text,date,text) TO authenticated;
NOTIFY pgrst, 'reload schema';
