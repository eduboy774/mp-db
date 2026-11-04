-- =====================================================================
-- Monthly billing: functions
-- Safe to run more than once (CREATE OR REPLACE).
--
-- Flow each month:
--   1. SELECT feesandcharges.mb_prepare_month();        -- builds bills, status PREPARED
--   2. review with 03_review.sql
--   3. CALL feesandcharges.mb_approve_run(<run_id>, '<your name>');
--        -> flags bills reuse_control_number = true; the backend's
--           ReUseControlNo job sends them to GePG within 15 minutes
--      or CALL feesandcharges.mb_discard_run(<run_id>);  -- throw away and re-run
--
-- Penalty rule (checked against application.june_bills / august_bills):
--   * 5% of the principal for every month unpaid, simple (not compounding).
--   * Principal first billed Jul-Dec  -> first penalty in January.
--   * Principal first billed Jan-Jun  -> first penalty the next month.
-- =====================================================================

-- Month number, used to count months between two dates.
CREATE OR REPLACE FUNCTION feesandcharges.mb_month_index(d date)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
    SELECT (extract(year FROM d) * 12 + extract(month FROM d))::integer;
$$;

-- First month that carries a penalty for a principal first billed on p_origin.
CREATE OR REPLACE FUNCTION feesandcharges.mb_first_penalty_month(p_origin date)
RETURNS date LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN extract(month FROM p_origin) >= 7
            THEN make_date(extract(year FROM p_origin)::int + 1, 1, 1)
        ELSE (date_trunc('month', p_origin) + interval '1 month')::date
    END;
$$;

-- Expected bill total for a control number when billed for p_month.
CREATE OR REPLACE FUNCTION feesandcharges.mb_expected_amount(p_control_number text, p_month date)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT coalesce(sum(
               p.principal_amt
             + p.penalty_amt * greatest(0, feesandcharges.mb_month_index(p_month)
                                         - feesandcharges.mb_month_index(p.first_penalty_month) + 1)
           ), 0)
    FROM feesandcharges.mb_principal p
    WHERE p.control_number = p_control_number
      AND p.status IN ('OPEN', 'NEEDS_REVIEW');
$$;

-- ---------------------------------------------------------------------
-- Preview one control number's bill for a month, line by line.
-- Read only: creates nothing. The control number must be in the ledger
-- (run SELECT feesandcharges.mb_sync(); first if it is new).
--   SELECT * FROM feesandcharges.mb_preview_bill('994720099726', '2026-11-01');
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION feesandcharges.mb_preview_bill(p_control_number text, p_month date DEFAULT NULL)
RETURNS TABLE (line_type text, for_month text, amount numeric, financial_year text, facility_id bigint, explanation text)
LANGUAGE sql STABLE AS $$
    WITH t AS (
        SELECT date_trunc('month', coalesce(p_month, (now() AT TIME ZONE 'Africa/Dar_es_Salaam')::date))::date AS m
    ), p AS (
        SELECT mp.*, fy.name AS fy_name
        FROM feesandcharges.mb_principal mp
        JOIN feesandcharges.financial_year fy ON fy.id = mp.financial_year_id
        WHERE mp.control_number = p_control_number AND mp.status IN ('OPEN', 'NEEDS_REVIEW')
    ), lines AS (
        SELECT 1 AS ord, p.id, NULL::date AS mon, p.item_type AS line_type, p.principal_amt AS amount,
               p.fy_name, p.facility_id,
               format('annual fee, first billed %s, penalties start %s%s',
                      p.origin_date, to_char(p.first_penalty_month, 'Mon YYYY'),
                      CASE WHEN p.status = 'NEEDS_REVIEW' THEN ' (NEEDS_REVIEW: ' || p.note || ')' ELSE '' END) AS explanation
        FROM p
        UNION ALL
        SELECT 2, p.id, g::date, 'PENALTY', p.penalty_amt, p.fy_name, p.facility_id,
               format('5%% of %s for %s', p.principal_amt, to_char(g, 'Mon YYYY'))
        FROM p, t, generate_series(p.first_penalty_month, t.m, interval '1 month') g
        WHERE p.first_penalty_month <= t.m
    )
    SELECT line_type, to_char(mon, 'YYYY-MM'), amount, fy_name, facility_id, explanation
    FROM (
        SELECT * FROM lines
        UNION ALL
        SELECT 3, NULL, NULL, 'TOTAL', sum(amount), NULL, NULL,
               format('%s principal + %s penalty line(s)',
                      count(*) FILTER (WHERE ord = 1), count(*) FILTER (WHERE ord = 2))
        FROM lines
    ) x
    ORDER BY ord, id, mon;
$$;

-- ---------------------------------------------------------------------
-- Seed the ledger from open bills that are not in it yet.
-- An open bill = the latest bill of its control number that is BILLED,
-- renewable, unpaid, not cancelled and not bulk.
-- Returns how many control numbers were added.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION feesandcharges.mb_seed()
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    tz          constant text := 'Africa/Dar_es_Salaam';
    h           record;
    pen         record;
    b           record;
    v_head_mon  date;
    v_c         integer;
    v_p         integer;
    v_origin    date;
    v_first     date;
    v_pgfs      bigint;
    v_expected  numeric;
    v_note      text;
    v_added     integer := 0;
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS _mb_base (
        item_id bigint, item_type text, amt numeric(15,2), unit numeric(15,2), n integer
    ) ON COMMIT DROP;

    FOR h IN
        WITH heads AS (
            SELECT DISTINCT ON (control_number) *
            FROM feesandcharges.bill
            WHERE control_number IS NOT NULL AND deleted_at IS NULL
            ORDER BY control_number, created_at DESC, id DESC
        )
        SELECT * FROM heads
        WHERE status = 'BILLED' AND renewable AND NOT is_paid
          AND NOT coalesce(cancelled, false) AND NOT is_bulk
          AND NOT EXISTS (SELECT 1 FROM feesandcharges.mb_principal p
                          WHERE p.control_number = heads.control_number
                            AND p.status IN ('OPEN', 'NEEDS_REVIEW'))
          -- Already read this exact bill before (e.g. closed as PAID because an
          -- earlier bill on the control number was paid): don't add it again.
          AND NOT EXISTS (SELECT 1 FROM feesandcharges.mb_principal p
                          WHERE p.source_bill_id = heads.id)
    LOOP
        TRUNCATE _mb_base;
        v_note := NULL;
        -- The month this bill covers = its expiry month.
        v_head_mon := date_trunc('month', h.bill_expr_dt AT TIME ZONE tz)::date;

        INSERT INTO _mb_base
        SELECT id, item_type, bill_item_amt, round(bill_item_amt * 0.05, 2), 0
        FROM feesandcharges.bill_item
        WHERE bill = h.id AND item_type IN ('PRINCIPAL', 'CARRYOVER');

        IF NOT FOUND THEN
            CONTINUE;   -- no principal on the bill; shows up in the review query
        END IF;

        -- Work out how many penalty months each principal already has.
        -- Penalty items are not linked to their principal, so match by amount
        -- (5% of the principal). Older (CARRYOVER) principals are matched first.
        FOR pen IN
            SELECT bill_item_amt AS amt, count(*)::int AS k
            FROM feesandcharges.bill_item
            WHERE bill = h.id AND item_type = 'PENALTY'
            GROUP BY bill_item_amt
        LOOP
            SELECT count(*) FILTER (WHERE item_type = 'CARRYOVER'),
                   count(*) FILTER (WHERE item_type = 'PRINCIPAL')
              INTO v_c, v_p
            FROM _mb_base WHERE unit = pen.amt;

            IF v_c > 0 AND pen.k % v_c = 0 THEN
                UPDATE _mb_base SET n = n + pen.k / v_c WHERE unit = pen.amt AND item_type = 'CARRYOVER';
            ELSIF v_c = 0 AND v_p > 0 AND pen.k % v_p = 0 THEN
                UPDATE _mb_base SET n = n + pen.k / v_p WHERE unit = pen.amt AND item_type = 'PRINCIPAL';
            ELSE
                v_note := concat_ws('; ', v_note,
                    format('%s penalty item(s) of %s could not be matched to a principal', pen.k, pen.amt));
            END IF;
        END LOOP;

        FOR b IN
            SELECT bb.n, bb.unit, bi.*
            FROM _mb_base bb JOIN feesandcharges.bill_item bi ON bi.id = bb.item_id
        LOOP
            -- First time this principal (same fee + facility) was billed under this control number.
            -- A PRINCIPAL is this financial year's fee, so only look from the start of its
            -- financial year; otherwise last year's bill with the same fee would be picked.
            SELECT min(x.created_at AT TIME ZONE tz)::date INTO v_origin
            FROM feesandcharges.bill x
            JOIN feesandcharges.bill_item xi ON xi.bill = x.id
            WHERE x.control_number = h.control_number
              AND x.deleted_at IS NULL
              AND xi.fee_id = b.fee_id
              AND xi.facility IS NOT DISTINCT FROM b.facility
              AND xi.item_type IN ('PRINCIPAL', 'CARRYOVER')
              AND (b.item_type <> 'PRINCIPAL'
                   OR x.created_at >= (SELECT date_trunc('day', fy.start_date)
                                       FROM feesandcharges.financial_year fy
                                       WHERE fy.id = b.financial_year_id));
            v_origin := coalesce(v_origin, (h.created_at AT TIME ZONE tz)::date);

            IF b.n > 0 THEN
                -- Trust what was already billed: n penalties ending in the head month.
                v_first := (v_head_mon - make_interval(months => b.n - 1))::date;
            ELSE
                v_first := feesandcharges.mb_first_penalty_month(v_origin);
            END IF;

            SELECT fp.gfs_id INTO v_pgfs
            FROM feesandcharges.fee_penalty fp WHERE fp.fee_id = b.fee_id LIMIT 1;

            INSERT INTO feesandcharges.mb_principal (
                control_number, source_item_id, source_bill_id, item_type, facility_id, fee_id,
                gfs_id, sub_sp_code, financial_year_id, quantity, coll_sp, principal_amt,
                penalty_amt, penalty_gfs_id, origin_date, first_penalty_month, status, note)
            VALUES (
                h.control_number, b.id, h.id, b.item_type, b.facility, b.fee_id,
                b.gfs_code, b.sub_sp_code, b.financial_year_id, coalesce(b.quantity, 1), b.coll_sp,
                b.bill_item_amt, b.unit, coalesce(v_pgfs, 1), v_origin, v_first, 'OPEN', NULL);
        END LOOP;

        -- Check: does the ledger reproduce the amount on the bill?
        v_expected := feesandcharges.mb_expected_amount(h.control_number, v_head_mon);
        IF v_expected <> h.bill_amt THEN
            v_note := concat_ws('; ', v_note,
                format('ledger gives %s for %s but bill %s has %s',
                       v_expected, to_char(v_head_mon, 'YYYY-MM'), h.bill_id, h.bill_amt));
        END IF;

        IF v_note IS NOT NULL THEN
            UPDATE feesandcharges.mb_principal
               SET status = 'NEEDS_REVIEW', note = v_note
             WHERE control_number = h.control_number AND status = 'OPEN';
        END IF;

        v_added := v_added + 1;
    END LOOP;

    RETURN v_added;
END;
$$;

-- ---------------------------------------------------------------------
-- Bring the ledger up to date: close what was paid or cancelled,
-- then add any new open bills.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION feesandcharges.mb_sync()
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    tz constant text := 'Africa/Dar_es_Salaam';
BEGIN
    -- Paid: any bill on the control number paid on or after this principal was billed.
    UPDATE feesandcharges.mb_principal p
       SET status = 'PAID', closed_at = now()
     WHERE p.status IN ('OPEN', 'NEEDS_REVIEW')
       AND EXISTS (SELECT 1 FROM feesandcharges.bill b
                   WHERE b.control_number = p.control_number
                     AND b.deleted_at IS NULL
                     AND b.is_paid
                     AND (b.created_at AT TIME ZONE tz)::date >= p.origin_date);

    -- Cancelled: the latest bill on the control number is cancelled.
    UPDATE feesandcharges.mb_principal p
       SET status = 'CANCELLED', closed_at = now()
     WHERE p.status IN ('OPEN', 'NEEDS_REVIEW')
       AND EXISTS (SELECT 1 FROM (
                       SELECT b.cancelled, b.status FROM feesandcharges.bill b
                       WHERE b.control_number = p.control_number AND b.deleted_at IS NULL
                       ORDER BY b.created_at DESC, b.id DESC LIMIT 1) last
                   WHERE coalesce(last.cancelled, false) OR last.status = 'CANCELLED');

    RETURN feesandcharges.mb_seed();
END;
$$;

-- ---------------------------------------------------------------------
-- Build next month's bills. Nothing is sent to GePG.
-- p_month: any date in the month to bill; default = current month.
-- Returns the run id.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION feesandcharges.mb_prepare_month(p_month date DEFAULT NULL, p_user_id bigint DEFAULT 1)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    tz          constant text := 'Africa/Dar_es_Salaam';
    v_today     date := (now() AT TIME ZONE tz)::date;
    v_target    date := date_trunc('month', coalesce(p_month, v_today))::date;
    v_expiry    timestamptz;
    v_run       bigint;
    v_cn        text;
    h           record;
    p           record;
    v_head_mon  date;
    v_bad       integer;
    v_expected  numeric;
    v_principal numeric(15,2);
    v_penalty   numeric(15,2);
    v_total     numeric(15,2);
    v_months    integer;
    v_abbr      text;
    v_bill_code text;
    v_new_id    bigint;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('mb_monthly_billing'));

    IF v_target < date_trunc('month', v_today)::date THEN
        RAISE EXCEPTION 'Cannot bill a past month (%). Bills must expire after they are created.', v_target;
    END IF;
    IF EXISTS (SELECT 1 FROM feesandcharges.mb_run
               WHERE billing_month = v_target AND status IN ('PREPARED', 'APPROVED')) THEN
        RAISE EXCEPTION 'A run for % already exists. Approve or discard it first.', to_char(v_target, 'YYYY-MM');
    END IF;

    -- End of the target month, 23:59:59 Dar es Salaam time.
    v_expiry := ((v_target + interval '1 month')::timestamp - interval '1 second') AT TIME ZONE tz;

    PERFORM feesandcharges.mb_sync();

    INSERT INTO feesandcharges.mb_run (billing_month) VALUES (v_target) RETURNING id INTO v_run;

    FOR v_cn IN
        SELECT DISTINCT control_number FROM feesandcharges.mb_principal o
        WHERE o.status = 'OPEN'
          AND NOT EXISTS (SELECT 1 FROM feesandcharges.mb_principal r
                          WHERE r.control_number = o.control_number AND r.status = 'NEEDS_REVIEW')
        ORDER BY 1
    LOOP
        SELECT * INTO h FROM feesandcharges.bill
        WHERE control_number = v_cn AND deleted_at IS NULL
        ORDER BY created_at DESC, id DESC LIMIT 1;

        v_head_mon := date_trunc('month', h.bill_expr_dt AT TIME ZONE tz)::date;

        IF h.status IS DISTINCT FROM 'BILLED' THEN
            INSERT INTO feesandcharges.mb_run_bill (run_id, control_number, previous_bill_id, result, message)
            VALUES (v_run, v_cn, h.id, 'SKIPPED',
                    format('latest bill %s has status %s, expected BILLED', h.bill_id, h.status));
            CONTINUE;
        END IF;

        IF v_head_mon >= v_target THEN
            INSERT INTO feesandcharges.mb_run_bill (run_id, control_number, previous_bill_id, result, message)
            VALUES (v_run, v_cn, h.id, 'SKIPPED',
                    format('latest bill %s already covers %s', h.bill_id, to_char(v_head_mon, 'YYYY-MM')));
            CONTINUE;
        END IF;

        -- The latest bill must still match the ledger (catches bills changed by hand).
        v_expected := feesandcharges.mb_expected_amount(v_cn, v_head_mon);
        IF v_expected <> h.bill_amt THEN
            UPDATE feesandcharges.mb_principal
               SET status = 'NEEDS_REVIEW',
                   note = format('latest bill %s has %s but ledger gives %s for %s',
                                 h.bill_id, h.bill_amt, v_expected, to_char(v_head_mon, 'YYYY-MM'))
             WHERE control_number = v_cn AND status = 'OPEN';
            INSERT INTO feesandcharges.mb_run_bill (run_id, control_number, previous_bill_id, result, message)
            VALUES (v_run, v_cn, h.id, 'SKIPPED', 'amount on latest bill does not match ledger; moved to NEEDS_REVIEW');
            CONTINUE;
        END IF;

        -- The current financial year's fee must be on the bill. Without it a payer could
        -- pay only the old debt, the control number would close, and this year's fee
        -- would never be billed. Add the new year's fee first (see README).
        IF NOT EXISTS (SELECT 1 FROM feesandcharges.mb_principal mp
                       JOIN feesandcharges.financial_year fy ON fy.id = mp.financial_year_id
                       WHERE mp.control_number = v_cn AND mp.status = 'OPEN'
                         AND mp.item_type = 'PRINCIPAL' AND fy.active)
           AND EXISTS (SELECT 1 FROM feesandcharges.financial_year fy
                       WHERE fy.active AND v_target >= date_trunc('month', fy.start_date)::date) THEN
            INSERT INTO feesandcharges.mb_run_bill (run_id, control_number, previous_bill_id, result, message)
            VALUES (v_run, v_cn, h.id, 'SKIPPED',
                    (SELECT format('no %s annual fee on this control number yet', name)
                     FROM feesandcharges.financial_year WHERE active LIMIT 1));
            CONTINUE;
        END IF;

        -- Bill items need an active facility (trigger bill_item101).
        SELECT count(*) INTO v_bad
        FROM feesandcharges.mb_principal mp
        LEFT JOIN feesandcharges.facility f ON f.id = mp.facility_id
        WHERE mp.control_number = v_cn AND mp.status = 'OPEN'
          AND mp.facility_id IS NOT NULL AND NOT coalesce(f.active, false);
        IF v_bad > 0 THEN
            INSERT INTO feesandcharges.mb_run_bill (run_id, control_number, previous_bill_id, result, message)
            VALUES (v_run, v_cn, h.id, 'SKIPPED', 'facility is not active');
            CONTINUE;
        END IF;

        BEGIN
            SELECT sum(principal_amt),
                   sum(penalty_amt * greatest(0, feesandcharges.mb_month_index(v_target)
                                               - feesandcharges.mb_month_index(first_penalty_month) + 1)),
                   max(greatest(0, feesandcharges.mb_month_index(v_target)
                                 - feesandcharges.mb_month_index(first_penalty_month) + 1))
              INTO v_principal, v_penalty, v_months
            FROM feesandcharges.mb_principal
            WHERE control_number = v_cn AND status = 'OPEN';
            v_total := v_principal + v_penalty;

            SELECT name_abbreviation INTO v_abbr
            FROM feesandcharges.collection_center WHERE code = h.coll_cent_code;
            v_abbr := coalesce(nullif(trim(v_abbr), ''), split_part(h.bill_id, '-', 2));
            LOOP
                v_bill_code := format('NEMC-%s-%s-%s', v_abbr, to_char(now() AT TIME ZONE tz, 'YYYYMMDD'),
                                      lpad(nextval('feesandcharges.mb_bill_seq')::text, 7, '0'));
                EXIT WHEN NOT EXISTS (SELECT 1 FROM feesandcharges.bill WHERE bill_id = v_bill_code);
            END LOOP;

            -- New bill: copy the header of the latest bill, new amount and dates.
            INSERT INTO feesandcharges.bill (
                created_at, created_by, updated_at, collection_center, currency, exchange_rate, vat,
                withholding, renewable, renewed, payer, req_id, sp_grp_code, sys_code, bill_typ, pay_typ,
                grp_bill_id, bill_id, sp_code, coll_cent_code, bill_desc, cust_name, bill_gen_dt,
                bill_expr_dt, billgenby, bill_gen_by, billapprby, bill_amt, ccy, bill_pay_opt, pay_plan,
                pay_lim_typ, coll_psp, bill_time_to_live, cust_id_type, cancelled, control_number,
                financial_year_id, is_aggregate, is_paid, bill_eqv_amt, min_pay_amt, pay_lim_amt,
                deleted_at, deleted_by, status, previous_bill_id, bill_amt_in_words, beneficiary_id,
                is_bulk, customer_tin, customer_id, customer_accnt, customer_name, customer_cellnum,
                customer_email, type, all_item, customer_idtyp, penalty_base_expr_dt, for_cancellation,
                renew_this_bill, reuse_control_number, for_notification)
            VALUES (
                now(), p_user_id, now(), h.collection_center, h.currency, h.exchange_rate, h.vat,
                h.withholding, true, false, h.payer,
                'SP' || (extract(epoch FROM clock_timestamp()) * 1000)::bigint || lpad(nextval('feesandcharges.mb_bill_seq')::text, 6, '0'),
                h.sp_grp_code, h.sys_code, h.bill_typ, h.pay_typ,
                v_bill_code, v_bill_code, h.sp_code, h.coll_cent_code, h.bill_desc, h.cust_name, now(),
                v_expiry, h.billgenby, h.bill_gen_by, h.billapprby, v_total, h.ccy, h.bill_pay_opt, h.pay_plan,
                h.pay_lim_typ, h.coll_psp, h.bill_time_to_live, h.cust_id_type, false, h.control_number,
                h.financial_year_id, true, false, v_total, h.min_pay_amt, h.pay_lim_amt,
                NULL, NULL, 'PREPARED', h.id,
                feesandcharges.number_to_words(trunc(v_total)::bigint) || ' Only', h.beneficiary_id,
                false, h.customer_tin, h.customer_id, h.customer_accnt, h.customer_name, h.customer_cellnum,
                h.customer_email, h.type, h.all_item, h.customer_idtyp, v_target::timestamp AT TIME ZONE tz, false,
                false, false, false)
            RETURNING id INTO v_new_id;

            -- Items: each principal, then one penalty item per month owed.
            FOR p IN
                SELECT * FROM feesandcharges.mb_principal
                WHERE control_number = v_cn AND status = 'OPEN'
                ORDER BY (item_type = 'CARRYOVER') DESC, id
            LOOP
                INSERT INTO feesandcharges.bill_item (
                    ref_bill_id, sub_sp_code, gfs_code, bill_item_ref, use_item_ref_on_pay, bill_item_amt,
                    bill_item_eqv_amt, coll_sp, bill, created_at, created_by, facility, fee_id, quantity,
                    financial_year_id, item_type, due_date, renew_this_bill_item)
                VALUES (
                    v_bill_code, p.sub_sp_code, p.gfs_id, lpad((floor(random() * 1e9))::bigint::text, 9, '0'), 'N',
                    p.principal_amt, p.principal_amt, p.coll_sp, v_new_id, now(), p_user_id, p.facility_id,
                    p.fee_id, p.quantity, p.financial_year_id, p.item_type, v_expiry, false);

                INSERT INTO feesandcharges.bill_item (
                    ref_bill_id, sub_sp_code, gfs_code, bill_item_ref, use_item_ref_on_pay, bill_item_amt,
                    bill_item_eqv_amt, coll_sp, bill, created_at, created_by, facility, fee_id, quantity,
                    financial_year_id, item_type, due_date, renew_this_bill_item)
                SELECT
                    v_bill_code, p.sub_sp_code, p.penalty_gfs_id, lpad((floor(random() * 1e9))::bigint::text, 9, '0'), 'N',
                    p.penalty_amt, p.penalty_amt, p.coll_sp, v_new_id, now(), p_user_id, p.facility_id,
                    p.fee_id, 1, p.financial_year_id, 'PENALTY', v_expiry, false
                FROM generate_series(p.first_penalty_month, v_target, interval '1 month') m
                WHERE p.first_penalty_month <= v_target;
            END LOOP;

            INSERT INTO feesandcharges.bill_facility (bill, facility)
            SELECT DISTINCT v_new_id, facility_id FROM feesandcharges.mb_principal
            WHERE control_number = v_cn AND status = 'OPEN' AND facility_id IS NOT NULL;

            INSERT INTO feesandcharges.mb_run_bill (run_id, control_number, previous_bill_id, new_bill_id,
                principal_amt, penalty_amt, total_amt, penalty_months, result)
            VALUES (v_run, v_cn, h.id, v_new_id, v_principal, v_penalty, v_total, v_months, 'OK');
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO feesandcharges.mb_run_bill (run_id, control_number, previous_bill_id, result, message)
            VALUES (v_run, v_cn, h.id, 'ERROR', SQLERRM);
        END;
    END LOOP;

    UPDATE feesandcharges.mb_run r SET
        bills_ok      = s.ok,
        bills_skipped = s.skipped,
        bills_error   = s.err,
        total_amt     = s.total,
        penalty_amt   = s.penalty
    FROM (SELECT count(*) FILTER (WHERE result = 'OK')      AS ok,
                 count(*) FILTER (WHERE result = 'SKIPPED') AS skipped,
                 count(*) FILTER (WHERE result = 'ERROR')   AS err,
                 coalesce(sum(total_amt)   FILTER (WHERE result = 'OK'), 0) AS total,
                 coalesce(sum(penalty_amt) FILTER (WHERE result = 'OK'), 0) AS penalty
          FROM feesandcharges.mb_run_bill WHERE run_id = v_run) s
    WHERE r.id = v_run;

    RETURN v_run;
END;
$$;

-- ---------------------------------------------------------------------
-- Approve a prepared run: hand the bills to the backend for GePG.
-- The backend's ReUseControlNo job (every 15 min) sends each bill with
-- reuse_control_number = true and sets it to BILLED when GePG accepts.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE feesandcharges.mb_approve_run(p_run bigint, p_approved_by text)
LANGUAGE plpgsql AS $$
DECLARE
    v_status text;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('mb_monthly_billing'));

    SELECT status INTO v_status FROM feesandcharges.mb_run WHERE id = p_run FOR UPDATE;
    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Run % not found', p_run;
    ELSIF v_status <> 'PREPARED' THEN
        RAISE EXCEPTION 'Run % is %, only PREPARED runs can be approved', p_run, v_status;
    ELSIF coalesce(trim(p_approved_by), '') = '' THEN
        RAISE EXCEPTION 'Say who is approving (p_approved_by)';
    END IF;

    -- Send the new bills.
    UPDATE feesandcharges.bill b
       SET reuse_control_number = true, updated_at = now()
      FROM feesandcharges.mb_run_bill rb
     WHERE rb.run_id = p_run AND rb.result = 'OK'
       AND b.id = rb.new_bill_id AND b.status = 'PREPARED';

    -- Retire the bills they replace.
    UPDATE feesandcharges.bill b
       SET status = 'OBSOLETE', renewed = true, updated_at = now()
      FROM feesandcharges.mb_run_bill rb
     WHERE rb.run_id = p_run AND rb.result = 'OK'
       AND b.id = rb.previous_bill_id AND b.status = 'BILLED' AND NOT b.is_paid;

    UPDATE feesandcharges.mb_run
       SET status = 'APPROVED', approved_at = now(), approved_by = p_approved_by
     WHERE id = p_run;
END;
$$;

-- ---------------------------------------------------------------------
-- Throw away a prepared (not approved) run so it can be prepared again.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE feesandcharges.mb_discard_run(p_run bigint)
LANGUAGE plpgsql AS $$
DECLARE
    v_status text;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('mb_monthly_billing'));

    SELECT status INTO v_status FROM feesandcharges.mb_run WHERE id = p_run FOR UPDATE;
    IF v_status IS DISTINCT FROM 'PREPARED' THEN
        RAISE EXCEPTION 'Run % is %, only PREPARED runs can be discarded', p_run, coalesce(v_status, 'missing');
    END IF;

    -- Soft delete, the same way the backend deletes bills (deleted_at set), so the
    -- app and these functions ignore them. A hard DELETE is very slow here because
    -- many tables reference bill without an index (see 04_optional_indexes.sql).
    CREATE TEMP TABLE _mb_discard ON COMMIT DROP AS
    SELECT b.id FROM feesandcharges.bill b
    JOIN feesandcharges.mb_run_bill rb ON rb.new_bill_id = b.id
    WHERE rb.run_id = p_run AND b.status = 'PREPARED' AND NOT b.reuse_control_number;

    DELETE FROM feesandcharges.bill_facility WHERE bill IN (SELECT id FROM _mb_discard);
    UPDATE feesandcharges.bill
       SET status = 'DISCARDED', deleted_at = now(), deleted_by = 0, updated_at = now()
     WHERE id IN (SELECT id FROM _mb_discard);

    UPDATE feesandcharges.mb_run SET status = 'DISCARDED', discarded_at = now() WHERE id = p_run;
END;
$$;
