-- =====================================================================
-- Optional: indexes on foreign keys that point at bill / bill_item.
-- Not needed for monthly billing, but without them any DELETE on bill or
-- bill_item scans all of these tables once per row (minutes for a few
-- thousand rows), and the backend's "find by bill" lookups are slower.
-- CONCURRENTLY = no write lock; run with plain psql, not inside a transaction.
-- =====================================================================
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_bill_previous_bill_id      ON feesandcharges.bill (previous_bill_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_bill_item_previous_item_id ON feesandcharges.bill_item (previous_bill_item_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_bill_facility_bill         ON feesandcharges.bill_facility (bill);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_invoice_bill               ON feesandcharges.invoice (bill);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_nbcnrx_bill                ON feesandcharges.normal_bill_control_number_request_xml (bill);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_penalty_detail_bill        ON feesandcharges.penalty_detail (bill_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_penalty_detail_agg_bill    ON feesandcharges.penalty_detail (aggregate_bill_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_bill_history_bill          ON feesandcharges.bill_history (bill_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_bill_cancel_req_bill       ON feesandcharges.bill_cancellation_request (bill_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_cn_cancel_req_bill         ON feesandcharges.control_number_cancellation_request (bill);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_bill_application_bill      ON feesandcharges.bill_application (bill);
