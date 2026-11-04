#!/usr/bin/env bash
# Prepares this month's bills. Nothing is sent to GePG; someone reviews
# and approves afterwards (see README.md).
#
# Cron on the database server, 1st of each month at 00:30 (server in EAT):
#   30 0 1 * *  /opt/nemc/monthly_billing/run_monthly_billing.sh >> /var/log/nemc/monthly_billing.log 2>&1
#
# Connection comes from the usual libpq settings (PGHOST, PGUSER, ~/.pgpass ...).
# Do not put the password in this file.
set -euo pipefail

DB="${PGDATABASE:-mazingira}"

echo "== $(date '+%F %T') preparing monthly bills in ${DB}"
RUN_ID=$(psql -d "$DB" -v ON_ERROR_STOP=1 -Atq -c "SELECT feesandcharges.mb_prepare_month();")
echo "run id: ${RUN_ID}"

psql -d "$DB" -v ON_ERROR_STOP=1 -P pager=off -c "
  SELECT id, billing_month, status, bills_ok, bills_skipped, bills_error, total_amt, penalty_amt
  FROM feesandcharges.mb_run WHERE id = ${RUN_ID};"

psql -d "$DB" -v ON_ERROR_STOP=1 -P pager=off -c "
  SELECT result, regexp_replace(coalesce(message,''), 'NEMC-[A-Z]+-[0-9]+-[0-9]+', '<bill>') AS reason, count(*)
  FROM feesandcharges.mb_run_bill WHERE run_id = ${RUN_ID}
  GROUP BY 1, 2 ORDER BY 3 DESC;"

echo "Review, then approve with:  CALL feesandcharges.mb_approve_run(${RUN_ID}, '<your name>');"
