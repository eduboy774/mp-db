# Monthly Billing

On the 1st of every month, this rebuilds every unpaid annual-fee bill with the month's penalty added. The new bills keep the same control number and wait for a person to approve them before anything goes to GePG.

**New here? Read [HOW_A_BILL_IS_MADE.md](HOW_A_BILL_IS_MADE.md) first.** It walks step by step from the annual fee to the bill sent to GePG, with worked examples.

It replaces the manual SQL that was run each month (the `application.april_bills`, `june_bills`, `august_bills` work) and the four overlapping database procedures (`run_bill_renewal`, `semwa1`, `sp_annual_bill_renewal_and_penalty`, `sp_renew_bills_jan`).

## The rule

For each unpaid annual fee (a "principal"):

- The bill is the principal plus **5% of the principal for each month unpaid**. The penalty is simple, not compounding.
- **The first penalty month** depends on when the principal was first billed:
  - billed July–December: first penalty in **January**;
  - billed January–June: first penalty in **the next month**.
- **From July**, last year's unpaid fee stays on the bill as `CARRYOVER` and keeps earning 5% a month. The new year's fee is added as `PRINCIPAL`.
- Each bill expires at the end of its month.

This rule matches all 3,694 rows of the team's June sheet. It also matches 4,785 of 4,795 November bills computed from the August sheet (the 10 differences are explained in [Tested](#tested)).

## How it works

```
1st of month ─► mb_prepare_month()          bills built, status PREPARED (GePG not involved)
                     │
              review (03_review.sql)
                     │
       ┌─────────────┴──────────────┐
mb_approve_run(id, 'name')     mb_discard_run(id)  ─► fix, prepare again
       │
new bills: reuse_control_number = true
old bills: OBSOLETE
       │
backend ReUseControlNo job (every 15 min) sends each bill to GePG,
sets it BILLED when GePG answers 7101
```

**Why prepared bills are safe:** GePG payments are matched by `bill_id`. A bill GePG has never seen therefore can't receive a payment.

### Ledger

The procedure keeps a ledger, `mb_principal`, with one row per principal still owed. It records the amount, its 5% penalty and its first penalty month. Every month's bill is **rebuilt from the ledger**, not cloned from last month's bill, which has two effects:

- If a month is skipped, the next run adds every missed penalty.
- If the same month is run twice, it is refused, so penalties can't be doubled.

The ledger fills itself from open bills the first time, and picks up new open bills on every run. An open bill is the latest bill of a control number that is BILLED, renewable, unpaid, not cancelled and not bulk. A principal is closed when any bill on its control number is paid, or when the latest one is cancelled.

### What a run skips

Skipped bills are listed with a reason in `mb_run_bill`:

| Reason | What to do |
|---|---|
| `no 2026/2027 annual fee on this control number yet` | The new financial year's fee was never added. Add it first (see [Not handled yet](#not-handled-yet)). This guard exists because, if a payer paid only the old debt, the control number would close and this year's fee would never be billed. |
| `latest bill … has status X, expected BILLED` | Last month's bill is still waiting for GePG, or was changed by hand. |
| `latest bill … already covers YYYY-MM` | Already billed for this month or later. Nothing to do. |
| `facility is not active` | The database refuses bill items for inactive facilities. Reactivate the facility or close the debt. |
| `amount on latest bill does not match ledger` | Someone changed the bill by hand. The control number moves to `NEEDS_REVIEW` (query 6 in `03_review.sql`). |

## Files

| File | What it is |
|---|---|
| `01_tables.sql` | Ledger and run tables, a sequence, and 2 indexes (`bill.control_number`, `bill_item.bill`). The `bill_item.bill` index turns a 7½-minute step into 4 seconds. |
| `02_functions.sql` | `mb_prepare_month`, `mb_approve_run`, `mb_discard_run`, plus helpers. |
| `03_review.sql` | Queries to check a run before approving it. |
| `04_optional_indexes.sql` | Indexes on 11 foreign keys that point at `bill`. Not required, but they make deletes and many backend lookups faster. |
| `run_monthly_billing.sh` | Cron entry point. It only prepares; it never approves. |

## Install (production)

1. Run these against the `mazingira` database **as plain psql**, not inside a transaction, because the indexes use `CONCURRENTLY`:
   ```bash
   psql -d mazingira -f 01_tables.sql
   psql -d mazingira -f 02_functions.sql
   psql -d mazingira -f 04_optional_indexes.sql   # optional
   ```
2. **Stop the old monthly steps.** Do not run the four old procedures or the manual monthly SQL any more. The backend's `JobPenalty` acts on bills with `renew_this_bill = true`. This process never sets that flag, so `JobPenalty` stays idle unless an old procedure sets it.
3. Schedule the prepare step. There is no pg_cron, so use cron on the DB server:
   ```
   30 0 1 * *  /path/to/run_monthly_billing.sh >> /var/log/nemc/monthly_billing.log 2>&1
   ```

## Each month

```sql
-- 1. (cron does this on the 1st, or run it by hand)
SELECT feesandcharges.mb_prepare_month();            -- returns the run id

-- 2. check it
\set run 2
\i 03_review.sql

-- 3a. send to GePG
CALL feesandcharges.mb_approve_run(2, 'Your Name');

-- 3b. or throw it away and prepare again
CALL feesandcharges.mb_discard_run(2);
```

Query 7 in `03_review.sql` shows the bills moving from `PREPARED` to `BILLED` as the backend sends them.

## Tested

All testing was on a local restore of the 2026-08-30 backup. **Nothing was run on production.**

- **Ledger seed:** 5,995 open control numbers in 4 s.
  - 13 were held as NEEDS_REVIEW. All 13 turned out to be already paid, and the next sync closed them as PAID.
- **November 2026 run:** 5,982 control numbers, 0 errors, about 4 s.
  - 4,785 bills built: 5.47 bn TZS in total, of which 576 m TZS is penalties.
  - Every bill's items add up to the bill amount, and every bill expires 2026-11-30.
  - 1,183 bills skipped because they have no 2026/27 fee.
- **Check against the team's August sheet:** 4,785 of 4,795 matched to the shilling. The other 10 were planned in the August sheet, but their August bill was never created, so they now fall under "no 2026/27 fee".
- **Approve:** new bills were flagged for GePG and old bills set to OBSOLETE.
  - Then GePG acceptance was simulated and December was prepared. Every one of the 4,785 bills equalled November plus exactly one month of penalty.
- **Discard:** works in 3 s, and re-preparing the same month works afterwards. A second live run for the same month is refused.

## Not handled yet

- **New financial year fee (July rollover).** 1,183 control numbers have no 2026/27 fee and are skipped. Adding it needs a decision: use the same amount as last year (what the August sheet did), or recompute from the fee table.
- **SMS to payers.** New bills have `for_notification = false`. Set it to true after GePG accepts them if payers should get the backend's penalty SMS.
- **`fee_penalty.rate` is 10 on every row, but 5% is what has actually been charged.** This procedure uses 5% (`mb_principal.penalty_rate`). Correct the table, or confirm which rate is right.
- **Partial payments.** The backend marks a bill PAID for any amount paid, and this process follows that.
