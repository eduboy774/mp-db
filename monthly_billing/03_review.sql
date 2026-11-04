-- =====================================================================
-- Monthly billing: review queries
-- Run these after mb_prepare_month() and before mb_approve_run().
-- Replace :run with the run id, or in psql:  \set run 2
-- =====================================================================

-- 1. Run summary
SELECT id, billing_month, status, bills_ok, bills_skipped, bills_error,
       total_amt, penalty_amt, prepared_at, approved_at, approved_by
FROM feesandcharges.mb_run
ORDER BY id DESC
LIMIT 5;

-- 2. Why bills were skipped or failed
SELECT result,
       regexp_replace(coalesce(message, ''), 'NEMC-[A-Z]+-[0-9]+-[0-9]+', '<bill>') AS reason,
       count(*)
FROM feesandcharges.mb_run_bill
WHERE run_id = :run
GROUP BY 1, 2
ORDER BY 3 DESC;

-- 3. Totals by collection centre
SELECT cc.name AS collection_centre, count(*) AS bills,
       sum(rb.principal_amt) AS principal, sum(rb.penalty_amt) AS penalty, sum(rb.total_amt) AS total
FROM feesandcharges.mb_run_bill rb
JOIN feesandcharges.bill b ON b.id = rb.new_bill_id
JOIN feesandcharges.collection_center cc ON cc.code = b.coll_cent_code
WHERE rb.run_id = :run AND rb.result = 'OK'
GROUP BY 1
ORDER BY 1;

-- 4. Bill by bill: old amount, new amount, penalty months
SELECT rb.control_number, b.bill_id, b.cust_name,
       prev.bill_amt AS previous_amt, rb.principal_amt, rb.penalty_amt, rb.total_amt, rb.penalty_months
FROM feesandcharges.mb_run_bill rb
JOIN feesandcharges.bill b    ON b.id = rb.new_bill_id
JOIN feesandcharges.bill prev ON prev.id = rb.previous_bill_id
WHERE rb.run_id = :run AND rb.result = 'OK'
ORDER BY rb.total_amt DESC;

-- 5. Items of one bill (put a control number in)
SELECT i.item_type, i.bill_item_amt, g.code AS gfs, fy.name AS financial_year, i.facility
FROM feesandcharges.mb_run_bill rb
JOIN feesandcharges.bill_item i ON i.bill = rb.new_bill_id
JOIN feesandcharges.gfs g ON g.id = i.gfs_code
JOIN feesandcharges.financial_year fy ON fy.id = i.financial_year_id
WHERE rb.run_id = :run AND rb.control_number = '994720099726'
ORDER BY i.item_type, i.id;

-- 6. Control numbers held back for a person to check
SELECT control_number, item_type, principal_amt, first_penalty_month, source_bill_id, note
FROM feesandcharges.mb_principal
WHERE status = 'NEEDS_REVIEW'
ORDER BY control_number;

-- 7. After approval: progress of sending to GePG
--    PREPARED + reuse flag = waiting for the backend job
--    BILLED                = GePG accepted
SELECT b.status, b.reuse_control_number, count(*)
FROM feesandcharges.mb_run_bill rb
JOIN feesandcharges.bill b ON b.id = rb.new_bill_id
WHERE rb.run_id = :run AND rb.result = 'OK'
GROUP BY 1, 2;
