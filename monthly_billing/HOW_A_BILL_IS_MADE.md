# How a Monthly Bill Is Made

This guide follows one facility's annual fee from its first bill to the monthly bill sent to GePG, including how the amount is worked out.

For installation and the file list, see [README.md](README.md).

---

## Overview

```
Step 1  Facility is billed its annual fee                     (backend, once a year)
Step 2  The fee goes into the ledger                          (database, automatic)
Step 3  On the 1st of each month: work out the new amount     (database, cron)
Step 4  Build the new bill with the same control number       (database, cron)
Step 5  A person reviews the run                              (NEMC staff)
Step 6  Approve, and the backend sends it to GePG             (NEMC staff, then backend)
Step 7  Payer pays, and the bill closes                       (GePG, then backend)
```

---

## Step 1: The annual fee is billed (backend)

The backend does this step, not the monthly job. When a facility is registered, or the annual bills are generated, the backend creates a bill with one **PRINCIPAL** line per annual fee.

**How the annual fee is calculated** (`BillService.applyBillItemLogicForAutoBill`):

```
annual fee = fee amount × facility unit measurement × quantity
```

1. Look up the facility's **sub-category**, for example "Abattoirs" or "Product depots for petrol, gas…".
2. Find that sub-category's fee in the `fee` table: the one that is **annual**, **active**, and has a **GFS code**.
3. Multiply the fee by the facility's `unit_measurement` and the `quantity`. Both are usually 1.

| Facility | Sub-category fee | × units | Annual fee |
|---|---|---|---|
| JS Electromec Ltd | 500,000 | × 1 | **500,000** |
| Hass Terminal Ltd | 4,500,000 | × 1 | **4,500,000** |

GePG returns a **control number**, for example `994720099800`. That control number stays with the facility's debt from then on.

**Expiry of this first bill:**

- Billed **July–December**: it expires **31 December**.
- Billed **January–June**: it expires at the **end of that month**.

---

## Step 2: The fee goes into the ledger (automatic)

Each month's run first looks for open bills it doesn't know yet. An open bill is the latest bill on a control number that is BILLED, renewable, unpaid, not cancelled and not bulk.

Each fee on such a bill becomes one row in the ledger table `mb_principal`:

| Field | Meaning | Example |
|---|---|---|
| `principal_amt` | The annual fee | 4,500,000 |
| `penalty_amt` | 5% of it, the penalty for one month | 225,000 |
| `origin_date` | When this fee was first billed | 2026-02-03 |
| `first_penalty_month` | First month that carries a penalty | 2026-03 |
| `item_type` | `PRINCIPAL` for this year's fee, `CARRYOVER` for last year's unpaid fee | CARRYOVER |

**Rule for the first penalty month:**

| Fee first billed | First penalty month | Example |
|---|---|---|
| July–December | **January** of the next year | billed 22 Aug 2025 → Jan 2026 |
| January–June | **The next month** | billed 3 Feb 2026 → Mar 2026 |

The ledger keeps the **original** fee and its start date. That is why every monthly bill can be rebuilt from scratch, without copying last month's bill.

**Check on entry:** the ledger must reproduce the amount on the facility's latest bill. If it doesn't, the control number is marked `NEEDS_REVIEW` and left out until a person checks it.

---

## Step 3: Work out the new amount (1st of each month)

For each open control number and the month being billed:

```
for each fee on the control number:
    months unpaid = months from first_penalty_month up to this month
                    (0 if first_penalty_month is still in the future)
    penalty       = 5% × fee × months unpaid

bill total = sum of all fees + sum of all penalties
```

The rules:

- The penalty is **always 5% of the original fee**. It is never charged on penalties: no compounding.
- **One penalty line per month**, so the payer can see each month separately.
- If a month was missed, its penalty is still counted. A skipped run therefore catches up on its own.

---

## Step 4: Build the new bill (1st of each month)

The run creates a **new bill** that:

- keeps the **same control number**, so the payer uses the same number as before;
- gets a new bill id, such as `NEMC-EZS-20261101-0000123`;
- copies the payer, collection centre, currency and GePG settings from the previous bill;
- expires at the **end of the month**, 23:59:59;
- has status **`PREPARED`**, which means GePG has not seen it yet;
- links to the bill it replaces (`previous_bill_id`).

**Bill lines**, in this order:

1. `CARRYOVER`: last year's unpaid fee, if any.
2. `PRINCIPAL`: this year's fee.
3. `PENALTY`: one line per month owed. These lines use GFS code `116101230009`, "Fines and Penalties".

**Bills that are not built.** Each of these is listed with its reason:

| Reason | Why |
|---|---|
| No fee for this financial year on the control number | Billing only the old debt could close the control number before this year's fee is billed. |
| Last bill still waiting for GePG | Don't stack a new bill on one GePG hasn't confirmed. |
| Already billed for this month | Prevents a double bill. |
| Facility not active | The database refuses bill lines for inactive facilities. |
| Amount changed by hand | The ledger no longer matches. A person must check it. |

---

## Step 5: Review (NEMC staff)

Nothing has gone to GePG yet, and a `PREPARED` bill cannot be paid. GePG matches payments by bill id, and it has never seen this one.

Check the run:

```sql
\set run 5
\i 03_review.sql
```

The review shows:

- totals for the run (number of bills, total amount, total penalty);
- why some bills were skipped;
- totals per collection centre;
- each bill: previous amount, new amount, and months of penalty.

To check one bill line by line:

```sql
SELECT * FROM feesandcharges.mb_preview_bill('994720099800', '2026-11-01');
```

If something is wrong: `CALL feesandcharges.mb_discard_run(5);`, fix it, and prepare again.

---

## Step 6: Approve and send to GePG

```sql
CALL feesandcharges.mb_approve_run(5, 'Your Name');
```

Approving does two things:

- The new bills are flagged for sending (`reuse_control_number = true`).
- The bills they replace are set to **OBSOLETE**.

Within 15 minutes, the backend's **ReUseControlNo** job then:

1. builds the GePG reuse request: same control number, new amount, new expiry;
2. signs it and sends it to GePG;
3. when GePG answers **7101 (OK)**, sets the bill to **BILLED**.

From then on the payer sees the new amount under the same control number.

---

## Step 7: Payment

When the payer pays, GePG notifies the backend. The backend then:

- marks the bill **PAID**;
- records the payment;
- writes a `facility_payment` row for each facility.

At the next monthly run, the ledger sees the payment and closes that fee as **PAID**. No more penalties are added.

---

## Worked examples (November 2026)

### Example 1: last year's fee unpaid, and this year's fee added (`994720099726`)

| Fee | Amount | First billed | Penalties start | Months to Nov 2026 | Penalty |
|---|---|---|---|---|---|
| 2025/26 (CARRYOVER) | 750,000 | 22 Aug 2025 | Jan 2026 | 11 | 11 × 37,500 = 412,500 |
| 2026/27 (PRINCIPAL) | 750,000 | 5 Aug 2026 | Jan 2027 | 0 | 0 |

**Bill = 750,000 + 750,000 + 412,500 = 1,912,500**

### Example 2: last year paid, this year's fee new (`994720094443`)

| Fee | Amount | First billed | Penalties start | Months to Nov 2026 | Penalty |
|---|---|---|---|---|---|
| 2026/27 (PRINCIPAL) | 500,000 | 5 Aug 2026 | Jan 2027 | 0 | 0 |

**Bill = 500,000**

### Example 3: first billed in the first half of the year (`994720099800`)

| Fee | Amount | First billed | Penalties start | Months to Nov 2026 | Penalty |
|---|---|---|---|---|---|
| 2025/26 (CARRYOVER) | 4,500,000 | 3 Feb 2026 | Mar 2026 | 9 | 9 × 225,000 = 2,025,000 |
| 2026/27 (PRINCIPAL) | 4,500,000 | 5 Aug 2026 | Jan 2027 | 0 | 0 |

**Bill = 4,500,000 + 4,500,000 + 2,025,000 = 11,025,000**

### What happens next month (December 2026)

Each fee already earning penalties gets one more month:

- Example 1: 1,912,500 + 37,500 = **1,950,000**
- Example 3: 11,025,000 + 225,000 = **11,250,000**
- Example 2: still **500,000**. Its penalties start in January 2027.

---

## Open points

- **New financial year fee.** 1,183 control numbers have no 2026/27 fee, so they are skipped for now. The rule for adding it still needs a decision: same amount as last year, or recalculated from the fee table.
- **Financial-year label on old fees.** CARRYOVER lines carry the year copied from the August bills (2026/27), but they belong to 2025/26. Amounts are correct; only reports split by year are affected.
- **Wrong fee reference.** 3 fees point to a different sub-category's fee than their facility's, for example an abattoir billed under the "chemical storage" fee. The amounts happen to be the same, but the references should be corrected.
- **Penalty rate in `fee_penalty`.** The table says 10 on every row, but 5% is what has always been charged. Confirm which is right.
