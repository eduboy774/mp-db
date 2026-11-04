-- =====================================================================
-- Monthly billing: tables
-- Safe to run more than once.
-- =====================================================================

-- Speeds up every "find the bills for this control number" lookup.
-- CONCURRENTLY avoids locking the bill table, so run this file with plain
-- psql (not inside a transaction / not with psql -1).
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_bill_control_number
    ON feesandcharges.bill (control_number);

-- bill_item has no index on its bill column; every "items of this bill"
-- lookup (here and in the backend) scans the whole table without it.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_bill_item_bill
    ON feesandcharges.bill_item (bill);

-- Used to make new bill ids unique.
CREATE SEQUENCE IF NOT EXISTS feesandcharges.mb_bill_seq START 1;

-- ---------------------------------------------------------------------
-- Ledger: one row per principal amount that is still owed.
-- Each month's bill is rebuilt from these rows, so a skipped or repeated
-- run can never double or miss a penalty.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS feesandcharges.mb_principal (
    id                  bigserial PRIMARY KEY,
    control_number      varchar(50)   NOT NULL,
    source_item_id      bigint        NOT NULL UNIQUE,   -- bill_item this principal was read from
    source_bill_id      bigint        NOT NULL,          -- bill that item belonged to
    item_type           varchar(20)   NOT NULL,          -- PRINCIPAL or CARRYOVER
    facility_id         bigint,
    fee_id              bigint        NOT NULL,
    gfs_id              bigint        NOT NULL,
    sub_sp_code         bigint        NOT NULL,
    financial_year_id   bigint        NOT NULL,
    quantity            integer       NOT NULL DEFAULT 1,
    coll_sp             text          NOT NULL,
    principal_amt       numeric(15,2) NOT NULL CHECK (principal_amt > 0),
    penalty_rate        numeric(6,4)  NOT NULL DEFAULT 0.05,
    penalty_amt         numeric(15,2) NOT NULL,          -- one month's penalty
    penalty_gfs_id      bigint        NOT NULL,
    origin_date         date          NOT NULL,          -- when this principal was first billed
    first_penalty_month date          NOT NULL,          -- first day of first month with a penalty
    status              varchar(20)   NOT NULL DEFAULT 'OPEN',  -- OPEN, NEEDS_REVIEW, PAID, CANCELLED
    note                text,
    created_at          timestamptz   NOT NULL DEFAULT now(),
    closed_at           timestamptz
);
CREATE INDEX IF NOT EXISTS idx_mb_principal_cn     ON feesandcharges.mb_principal (control_number);
CREATE INDEX IF NOT EXISTS idx_mb_principal_status ON feesandcharges.mb_principal (status);

-- ---------------------------------------------------------------------
-- One row per monthly run.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS feesandcharges.mb_run (
    id             bigserial PRIMARY KEY,
    billing_month  date        NOT NULL,                 -- first day of the month billed
    status         varchar(20) NOT NULL DEFAULT 'PREPARED', -- PREPARED, APPROVED, DISCARDED
    bills_ok       integer     NOT NULL DEFAULT 0,
    bills_skipped  integer     NOT NULL DEFAULT 0,
    bills_error    integer     NOT NULL DEFAULT 0,
    total_amt      numeric(18,2) NOT NULL DEFAULT 0,
    penalty_amt    numeric(18,2) NOT NULL DEFAULT 0,
    prepared_at    timestamptz NOT NULL DEFAULT now(),
    approved_at    timestamptz,
    approved_by    text,
    discarded_at   timestamptz,
    note           text
);
-- At most one live (prepared or approved) run per month.
CREATE UNIQUE INDEX IF NOT EXISTS uq_mb_run_month_live
    ON feesandcharges.mb_run (billing_month) WHERE status IN ('PREPARED', 'APPROVED');

-- ---------------------------------------------------------------------
-- One row per control number looked at in a run.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS feesandcharges.mb_run_bill (
    id               bigserial PRIMARY KEY,
    run_id           bigint      NOT NULL REFERENCES feesandcharges.mb_run(id),
    control_number   varchar(50) NOT NULL,
    previous_bill_id bigint,
    new_bill_id      bigint,
    principal_amt    numeric(15,2),
    penalty_amt      numeric(15,2),
    total_amt        numeric(15,2),
    penalty_months   integer,
    result           varchar(10) NOT NULL,   -- OK, SKIPPED, ERROR
    message          text
);
CREATE INDEX IF NOT EXISTS idx_mb_run_bill_run ON feesandcharges.mb_run_bill (run_id, result);
