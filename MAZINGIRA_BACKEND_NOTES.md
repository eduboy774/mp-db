# Mazingira Backend: Database and Backend Notes

Reference notes from reviewing `../mazingira-backend` alongside a production database restore.

- **Reviewed:** 2026-11-03
- **Backend repo:** `NEMC-MP/mazingira-backend`. Last commit at review time: `96adc205 ix notificaion`.
- **Database dump:** `mazingira_backup.dump`, created 2026-08-30 from PostgreSQL 16.14.

> These notes describe the code and data as they were on the review date. Line numbers drift, so search for the class or method name if a reference no longer matches.

---

## Contents

1. [Restoring the database locally](#1-restoring-the-database-locally)
2. [System overview](#2-system-overview)
3. [Database design](#3-database-design)
4. [Backend structure and API](#4-backend-structure-and-api)
5. [Business flows](#5-business-flows)
6. [RabbitMQ topology](#6-rabbitmq-topology)
7. [Scheduled jobs](#7-scheduled-jobs)
8. [Security and authentication](#8-security-and-authentication)
9. [Integrations](#9-integrations)
10. [Known issues and risks](#10-known-issues-and-risks)
11. [Running locally safely](#11-running-locally-safely)

---

## 1. Restoring the database locally

The dump is the PostgreSQL custom format. Fetch it with the command in `starter.sql`:

```bash
scp nemc-admin@database.nemc.or.tz:/home/nemc-admin/mazingira_backup.dump ~/Downloads/
```

Restore it into a new local database:

```bash
createdb mazingira
pg_restore -d mazingira --no-owner --no-acl -j 4 ~/Downloads/mazingira_backup.dump
```

- `--no-owner --no-acl` is needed because server roles such as `mmsnemcdba` do not exist locally. Every object ends up owned by your local user.
- The restore takes a few minutes. The result is about **1.6 GB**.
- The restore finished on 2026-11-03 with no errors.

**What a restore contains**

| Schema | Contents |
|---|---|
| `feesandcharges` | The application. It has 77 tables, 11 views, functions, triggers and procedures. |
| `application` | 21 ad-hoc working tables such as `april_bills`, `august_not_paid` and `forsms`. No code uses them. They look like monthly operations snapshots. |
| `mazingira` | Empty, both in the dump and in the restore. |

The database also holds about **1.09 million large objects**. Section 3.6 explains where they come from.

---

## 2. System overview

The backend is NEMC's **Fees and Charges / billing system**. It produces annual environmental fee bills for facilities and collects payment through **GePG**, the Tanzania Government e-Payment Gateway.

**Stack**

| Area | Technology |
|---|---|
| Language and framework | Java 17, Spring Boot 3.5.0, Gradle |
| Database | PostgreSQL. The app connects with `jdbc:postgresql://localhost:5432/mazingira?currentSchema=feesandcharges`. |
| Messaging | RabbitMQ |
| Auth | JWT for web users. A Spring OAuth2 Authorization Server issues machine-client tokens. |
| Reports | JasperServer (PDF bills), Apache Superset dashboards |
| Notifications | mGov SMS gateway, Gmail SMTP |
| Mapping | MapStruct, Lombok |

- The app runs on port **8083**, bound to `127.0.0.1`.
- Swagger UI is at `/swagger-ui/index.html`.
- The main package is `com.nemc.mms`. The main class is `DemoApplication`. The built jar is called `mms-backend`.

**Core domain in one line:** a **Client** (payer, identified by TIN) owns **Facilities**. Each facility has a **Sub-category**, which has **Fees**. A **Bill** is made of **Bill items** (fee × facility). The bill is sent to GePG, which returns a **control number**. The client pays, and the payment comes back through GePG.

---

## 3. Database design

### 3.1 Core relationships

```
users ─< user_clients >─ clients ──> client_categories
  │                        │  └──> collection_center ─< collection_center_administrative >─ administrative (region→village tree)
  └─ employees (department, designation)
                           │
                           └─< facility (owned_by) ──> facility_sub_category ──> facility_category ──> facility_type
                                   └──> administrative (village), unit_type, collection_center

fee ──> facility_sub_category, gfs, financial_year
fee_penalty ──> fee, gfs, facility_sub_category

clients ─< bill (payer) ──> currency, exchange_rate, vat, withholding, beneficiary, financial_year, bill (previous)
             ├─< bill_facility >─ facility
             ├─< bill_item ──> fee, facility, gfs, sub_sp_code, financial_year ; 1:1 penalty_detail
             ├─< penalty_detail (bill_id / aggregate_bill_id)
             ├─< invoice (GePG control number response) ── payment ─< PmtTrxDtl
             ├─< bill_cancellation_request ──> users (requested_by / approved_by)
             ├─< bill_history ─< bill_item
             └─< normal_bill_control_number_request_xml

facility ─< facility_payment ──> clients, financial_year
```

Some tables have **no foreign keys** and link only by string or number:

- `payment_inbox`
- `gpg_control_number_callback`
- `reconciliation_request`, `reconciliation_response`, `reconciliation_pmt`
- `control_number_cancellation_request.bill`
- `bill_application.bill` and `bill_application.application`
- `approvals.model` with `approvals.model_id`

### 3.2 Tables by domain

**Users, auth and organisation**

| Table | Notes |
|---|---|
| `users` | Holds the lockout and session columns (`login_attempts`, `account_locked_until`, `current_session_id`), `collection_center` and `account_status` (enum). |
| `roles`, `permissions`, `role_permissions`, `user_roles` | Permission-based access control. `permissions` is filled automatically at startup from `@PreAuthorize` expressions. |
| `user_types` | Element collection of `CLIENT`, `CONSULTANT` or `EMPLOYEE`. |
| `user_clients` | Many-to-many link between users and clients. |
| `employees`, `departments`, `designations` | Staff records. |
| `account_activation_tokens`, `password_reset_tokens` | `password_reset_tokens` has no entity; reset tokens are actually held in memory. |
| `audit_logs` | Stores entity and id as strings. |
| `oauth2_registered_client` | Spring Authorization Server clients. |

**Clients and facilities**

| Table | Notes |
|---|---|
| `clients` | Payers. `client_type` is `DEVELOPER` or `EXPERT`. |
| `client_categories` | |
| `facility` | Unique on (name, village, owned_by). `business_license` is unique. The facility code follows `NEMC-{cc}-{Region}-{nnn}`. |
| `facility_type` → `facility_category` → `facility_sub_category` | The primary-key column is named `identity`, not `id`. |
| `unit_type` | |
| `administrative` | Self-referencing region → district → ward → village tree with `level`. Villages are level 5. |
| `collection_center` | NEMC zone offices. `code` is unique. |

**Fee catalogue and reference data**

| Table | Notes |
|---|---|
| `fee` | Linked to a sub-category, GFS code and financial year. Has `amount`, `annually` and `active`. |
| `fee_penalty` | Penalty `rate` for each fee or sub-category. |
| `gfs` | Government revenue (GFS) codes. |
| `financial_year` | |
| `currency`, `exchange_rate`, `vat`, `withholding` | |
| `sp_code`, `sub_sp_code` | GePG service provider codes. |
| `beneficiary` | Bank account details. |
| `static_config` | GePG constants: spGrpCode, sysCode, billTyp, TTL and others. |

**Billing, payments and GePG**

| Table | Notes |
|---|---|
| `bill` | The central table. Has `status` (text), `control_number`, and the flags `is_paid`, `cancelled`, `renewed`, `is_aggregate`, `is_bulk`. Soft delete uses `deleted_at`. |
| `bill_item` | `item_type` is `PRINCIPAL`, `CARRYOVER` or `PENALTY`. |
| `bill_facility` | Link between bill and facility. |
| `bill_history` | Snapshot data. |
| `penalty_detail` | |
| `invoice` | GePG control-number response (`cust_cntr_num`, `res_sts*`). |
| `payment`, `PmtTrxDtl` | Column names are PascalCase. |
| `payment_inbox` | Queue of raw GePG payment notifications, with `processed`, `attempts` and `last_error`. |
| `facility_payment` | One row per facility per payment. These rows are pushed to MMA. |
| `gpg_control_number_callback` | Raw **control-number** callbacks. The name suggests payments, but it holds control-number callbacks. |
| `normal_bill_control_number_request_xml` | Signed XML sent to GePG. |
| `bill_cancellation_request`, `control_number_cancellation_request`, `cancellation_bills` | |
| `reconciliation_request`, `reconciliation_response`, `reconciliation_pmt` | |

**Workflow:** `approval_work_flows`, `approval_work_flow_stages`, `approval_work_flow_stage_actions`, `approval_work_flow_stage_attachments`, `approval_work_flow_stage_attachment_types`, `approvals` and `approval_attachments`. These are **scaffolding only**. No entity uses them. See section 5.8.

**Other tables:** `report`, `report_group`, `level`, `messages` (SMS templates) and `data_import_tracker`.

**Backup and snapshot tables that are not part of the app:**

- `bill_march2026`, `bill_item_march2026`
- `penalty_detail_feb2026`
- `bill_penalty_base_backup_20260210_all_10813`
- `bill_recovery_20260215`
- `bill_deffered`
- `testing`

**Views:**

- `client_statistics_view`, `client_statistics_by_collection_center_view`
- `client_type_statistics_view`, `collection_center_client_type_statistics_view`
- `client_users`, `client_users_summary`
- `department_with_employee_count`, `designation_with_employee_count`
- `v_administrative_hierarchy`
- `v_collection_center_user_statistics`, `v_user_statistics`

### 3.3 Data volumes (restore of 2026-08-30)

| Table | Rows (approx.) | Size |
|---|---|---|
| bill_item | 253,500 | 81 MB |
| bill | 70,700 | 65 MB |
| normal_bill_control_number_request_xml | 497,000 | 45 MB (plus large objects) |
| gpg_control_number_callback | 194,800 | 27 MB |
| facility | 17,200 | 20 MB |
| invoice | 79,500 | 17 MB |
| bill_facility | 141,500 | 10 MB |
| fee | 15,600 | 9.6 MB |
| payment_inbox | 8,900 | 7.9 MB |
| clients | 8,000 | 7.3 MB |
| facility_payment | 38,700 | 7.3 MB |
| administrative | 27,100 | 5.9 MB |
| payment | 8,900 | 4.7 MB |
| users | 41 | |

**Bill status distribution**

| Status | Bills |
|---|---|
| BILLED | 30,605 |
| OBSOLETE | 21,673 |
| PAID | 8,935 |
| CANCELLED | 8,889 |
| SUBMITTED | 567 |
| BILL | 11 |
| CREATED | 5 |
| BILL ME | 4 |

`BILL`, `BILL ME` and `OBSOLETE` do not exist in the `BillStatus` enum. They were probably set directly with SQL.

### 3.4 Status values and enums

| Field | Values |
|---|---|
| `bill.status` (`BillStatus`, stored as text) | CREATED → SUBMITTED → BILLED → PAID; CANCELLATION → CANCELLED |
| `bill_item.item_type` | PRINCIPAL, CARRYOVER, PENALTY |
| `bill_cancellation_request.status` | PENDING, APPROVED, REJECTED |
| `users.account_status` | PENDING, ACTIVE, SUSPENDED, INACTIVE, REJECTED |
| `user_types` | CLIENT, CONSULTANT, EMPLOYEE |
| `clients.client_type` | DEVELOPER, EXPERT |
| Workflow `ApprovalStatus` | PENDING, ONGOING, COMPLETE, CANCELLED, REJECTED |
| SMS `Target` | PAID, UNPAID, ALL, EXPIRED, PENALTY, BILL, WISHES |

These integer codes have no enum or documentation:

- `facility.status`
- `collection_center.status`
- `exchange_rate.status`
- `payment.Status` and `payment.Type`
- the GePG fields `bill_typ`, `pay_typ`, `bill_pay_opt`, `pay_plan`, `pay_lim_typ` and `cust_id_type`

### 3.5 Conventions

- **IDs:** most tables use a bigint identity plus a separate `uuid` column. Exceptions:
  - Several tables name the key `identity`.
  - `sp_code` and `sub_sp_code` use Integer ids.
  - `account_activation_tokens` uses a String key.
- **Audit columns:** `created_at`, `created_by`, `updated_at` and `updated_by`. The `*_by` columns hold user ids with no foreign key. There is no shared base class.
- **Timestamps:** billing tables use `ZonedDateTime` and user/HR tables use `LocalDateTime`. The default zone is Africa/Nairobi.
- **Soft delete:** only `bill` has it (`deleted_at`). Most other tables use an `active` boolean instead.
- **Column naming is inconsistent:** mostly snake_case, but PascalCase in `payment`/`PmtTrxDtl` and camelCase in `normalbillcontrolnumberfinalresponse`.

### 3.6 Large objects

The `xml` column in `normal_bill_control_number_request_xml` (and similar XML/payload columns) is of type `text`, but it **stores a large-object ID, not the XML**.

```sql
SELECT xml FROM feesandcharges.normal_bill_control_number_request_xml LIMIT 1;
-- 1313384   ← an OID, not XML
```

This is a side effect of JPA `@Lob` on a `String` field with the Postgres driver. It explains the ~1.09M large objects in the database. To read the actual XML:

```sql
SELECT convert_from(lo_get(xml::oid), 'UTF8')
FROM feesandcharges.normal_bill_control_number_request_xml
LIMIT 1;
```

Deleting rows does **not** delete their large objects. Orphans build up until `vacuumlo` is run.

> ✅ **Many of these rows do not hold the request XML that was sent.** The newest rows decode to GePG's acknowledgement JSON (`{"ackId":…,"ackStsCode":"7101",…}`), because `AckBillConsumer` overwrites the stored request with the ack. So the original signed XML sent to GePG is often not kept.

### 3.7 Liquibase is not the source of truth

- `spring.liquibase.enabled=false`.
- The master changelog includes only about 14 small migrations: 0000–0011, 0013 and 0014.
- Most core tables (`bill`, `bill_item`, `users`, `roles`, `invoice`, `payment` and others) have **no create changelog**.
- Many changelog files are not included anywhere, and some use duplicate number prefixes.
- Some changesets hard-code `schemaName: public`.

**Treat the restored database as the real schema**, not the changelogs. To get a schema-only reference:

```bash
pg_dump -s -n feesandcharges mazingira > feesandcharges_schema.sql
```

---

## 4. Backend structure and API

All paths below are under `src/main/java/com/nemc/mms/`.

| Package | Purpose |
|---|---|
| `controller/` | REST controllers (about 53) |
| `service/`, `service/jobs/`, `service/adhoc/` | Business logic and scheduled jobs |
| `consumers/` | RabbitMQ listeners |
| `model/`, `repository/`, `dto/`, `mappers/` | JPA entities, repositories, DTOs, MapStruct mappers |
| `security/`, `oauth2/` | JWT filter, security config, OAuth2 Authorization Server |
| `workflowutils/` | Approval workflow engine (unused) |
| `messageclone/` | Bulk SMS templates and queue |
| `mma/` | MMA mobile app integration |
| `validation/` | `@TanzanianTin`, `@TanzanianPhone`, `@TanzanianNida`, `@StrongPassword` |
| `util/` | GePG signing helpers, permission scanner, bootstrap admin |

### Main endpoints

| Controller | Base path | Purpose |
|---|---|---|
| `BillController` | `/api/v1/bills` | Create bills, generate facility bills, request control numbers, reconciliation, queries |
| `BillCancellationController` | `/api/v1/cancellations` | Create, approve, reject and cancel bill cancellations |
| `GePGCallbackController` | `/api/v1/gepg/callback` | **Public** XML callbacks: `/bill-response`, `/payment-response`, `/reconciliation-response` |
| `FacilityController` | `/api/v1/facilities` | Facility CRUD |
| `ClientRegistrationController` / `ClientController` | `/api/v1/clients` | Client registration and queries |
| `PaymentController` | `/api/v1/payments` | Payments |
| `FacilityPaymentController` | `/api/v1/facility-payments` | Facility payments |
| `ReconciliationPmtTrxDtlController` | `/api/v1/reconciliation` | Reconciliation data |
| `FeeController` | `/api/v1/fees` | Fees catalogue |
| Facility type/category/sub-category controllers | `/api/v1/facility-*` | Plus `/mobile` reads |
| Reference data controllers | various | Currency, exchange rate, VAT, withholding, GFS, SP codes, financial years, collection centers, administratives, static configurations |
| `AuthController` | `/api/v1/auth` | Login, refresh, logout, password reset, activation |
| User/Role/Permission/Employee controllers | `/api/v1/...` | User and role administration |
| `JasperReportController` | `/api/v1/jasper` | Reports and bill PDFs |
| `SupersetController` | `/api/v1/guest-token/{id}` | Superset guest tokens |
| `MobileClientController` | `/api/v1/mobile/clients` | MMA client sync (OAuth2 JWT) |
| `MobileFacilityController` | `/api/v2/mobile/facilities` | MMA facility sync (**public**) |
| `MMARequestControlNo` | `/api/v2/mobile/control-no-requests` | MMA bill creation (**public**) |
| `MessageJobController` | `/api/v1/message` | Bulk SMS |
| `OAuth2ClientController` | `/api/v1/oauth2/clients` | Machine-client administration |

---

## 5. Business flows

### 5.1 Client registration

- **Web:** `ClientRegistrationService.registerClient` checks for duplicates, then resolves the collection center and category.
- **Mobile (MMA):** `MobileClientService.createOrUpdateClient` creates or updates the client by TIN.

### 5.2 Facility registration and the automatic annual bill

1. References are resolved in `FacilityService.resolveReferences` (web) or `MobileFacilityService.resolveReferences` (mobile).
2. Validation runs. The location must be a village (level 5), and name + village + owner must be unique. Mobile requests also reject sub-categories with no fees or with inactive fees.
3. A facility code `NEMC-{ccAbbr}-{Region}-{count+1}` is generated.
4. If the sub-category has annual fees, `BillService.generateFacilityBillsFromFees(facilityId)` creates the bill automatically.

### 5.3 Bill creation (`service/BillService.java`)

- **Annual bill.** `generateFacilityBillsFromFees` builds the bill from active annual fees that have a GFS code:
  1. It applies the GePG constants from `static_config`.
  2. It generates the bill ID `NEMC-{cc}-{yyMMdd}-{n}`.
  3. It computes each item as `fee.amount × unitMeasurement × qty`.
  4. It sets the TTL: bills created Jan–Jun expire at the end of the month, bills created Jul–Dec on 31 December.
  5. After the transaction commits, it calls `requestControlNumber`.
- **Manual or bulk bill.** `create` handles these. Bulk bills first cancel the facility's existing renewable bills at GePG. Item amounts can come from the request payload.

### 5.4 Requesting a control number from GePG

1. `requestControlNumberForBill` adds a penalty item if one applies.
2. It chooses between a **normal** submission and a **reuse** submission. Reuse applies when the bill is renewable, covers a single facility, and that facility already has a control number.
3. `GePGService` builds `<billSubReq>` XML, signs it with SHA256withRSA, stores the XML and publishes it to RabbitMQ.
4. `BillSendToGepgConsumer` posts it to GePG and sets the bill to `SUBMITTED`.
5. `AckBillConsumer` creates an `Invoice`.

Aggregate or combined bills (`generateCombinedBill`) copy unpaid items from earlier years as CARRYOVER and add a 5% penalty.

### 5.5 Control number callback

1. GePG calls `POST /gepg/callback/bill-response`.
2. The controller verifies the signature and queues the message to `bill.q.db`.
3. `BillSaveToDbConsumer` saves it to `gpg_control_number_callback`.
4. The `GePGCallbackScheduler` job (every 5 s) sets `bill.control_number`, copies it to the bill's facilities, sets status `BILLED` and updates the invoice.

### 5.6 Payment

1. GePG calls `POST /gepg/callback/payment-response`.
2. The message goes to the `payment.q.gepg` queue, and `PaymentConsumer` writes it to `payment_inbox`.
3. `PaymentInboxProcessor` (every minute) calls `PaymentProcessingService.processPayment`. That creates the `payment`, sets the bill to `PAID` and `is_paid=true`, and writes one `facility_payment` row per facility.
4. `NotifyMmaPaidBIlls` (every 10 min) pushes the paid facilities to MMA.

### 5.7 Reconciliation, cancellation, reuse and penalties

- **Reconciliation:** runs daily at 10:00 for the previous day, or manually through `/bills/{date}/reconciliation`. The responses are stored in `reconciliation_pmt`. **Nothing matches them against payments.**
- **Cancellation:** a request is created (PENDING) and then approved. Approval marks the bill CANCELLED and sends `<billCanclReq>` to GePG. GePG code 7283 means success.
- **Batch jobs** run off flags on `bill`:
  - `forCancellation` → the `CancelBIlls` job
  - `forReuse` → the `ReUseControlNo` job
  - `renewThisBill` → the `JobPenalty` job, which clones the bill with a penalty item and resends it with the **same control number**
  - `forNotification` → the `Notifications` job

> **Important:** the Java code never sets `forReuse`, `forCancellation`, `forNotification`, `renewThisBill` or `billItemPenaltyAmt`. Something outside the app must set them, probably SQL scripts or database jobs (possibly in this `mp-db` folder).

### 5.8 Workflow engine

The `workflowutils/` package implements multi-stage approvals: stages, approval modes (ROLE, DESIGNATION or DEPARTMENT) and actions such as COMMIT, REJECT and RETURN_TO_CLIENT. Its tables exist, but **no entity uses it**. Bill cancellation uses its own simpler PENDING/APPROVED/REJECTED status instead.

---

## 6. RabbitMQ topology

- **Exchanges:** `billexchange` (main) and `billretryexchange` (retry).
- **Retry:** each retry queue has a 10 s TTL and dead-letters back to the main exchange. **There is no maximum retry count.**

| Queue | Consumer | Action |
|---|---|---|
| `bill.q.gepg` | `BillSendToGepgConsumer` | Posts the bill to GePG and sets SUBMITTED |
| `bill.q.gepg.reuse` | `BillSendToGepgConsumer` | Posts a reuse bill to GePG |
| `ack.q.bill`, `ack.q.bill.reuse` | `AckBillConsumer` | Creates the invoice |
| `bill.q.db` | `BillSaveToDbConsumer` | Saves the control-number callback |
| `payment.q.gepg` | `PaymentConsumer` | Writes to `payment_inbox` |
| `reconciliation.q.gepg` | `ReconciliationSendToGepgConsumer` | Posts the reconciliation request |
| `reconciliation.q.db` | `ReconciliationSaveToDbConsumer` | Saves reconciliation rows |
| `cancellation.q.gepg` | `BillCancellationSendToGepgConsumer` | Posts the cancellation |
| `send.message.to.client.q` | `SmsQueueConsumer` | Sends bulk SMS |
| `adhoc_cancel_bill_queue` | `CancelBIlls` | Batch cancellation |
| `adhoc_reuse_bill_queue` | `ReUseControlNo` | Batch reuse |
| `adhoc_notification_queue` | `Notifications` | Sends SMS and email |
| `adhoc_sms_queue`, `adhoc_email_queue` | **none** | Messages pile up unread |

---

## 7. Scheduled jobs

> `app.scheduling.enabled=false` **does not stop these jobs.** `DemoApplication` has `@EnableScheduling`, so every job always runs.

| Job | Schedule | Action |
|---|---|---|
| `GePGCallbackScheduler` | every 5 s | Processes control-number callbacks → BILLED |
| `PaymentInboxProcessor` | every 1 min | Processes payments → PAID |
| `Notifications` | every 5 min | Sends SMS and email for bills with `forNotification` set |
| `CancelBIlls` | every 15 min | Sends GePG cancellations for bills with `forCancellation` set |
| `ReUseControlNo` | every 15 min | Sends GePG reuse requests for bills with `forReuse` set |
| `JobPenalty` | hourly at :15 | Clones bills with a penalty and resends them |
| `NotifyMmaPaidBIlls` | every 10 min | Pushes paid facilities to MMA |
| `ReconciliationPmtTrxDtlService` | daily 10:00 | Requests yesterday's reconciliation |
| `LoginAttemptService` | every 5 min | Unlocks locked accounts |
| `TempAggregatePenaltyBillCancellationService` | 11 Feb 20:15 | One-off job that is still active |

---

## 8. Security and authentication

### Filter chains

| Order | Config | Covers |
|---|---|---|
| 1 | `OAuth2AuthorizationServerConfig` | `/oauth2/token`, `/oauth2/jwks` and related endpoints. Clients are stored in `oauth2_registered_client`. |
| 2 | `ClientApiSecurityConfig` | `/api/v1/mobile/**`. Requires an OAuth2 JWT. |
| default | `SecurityConfig` | Everything else. Stateless; `JwtAuthFilter` checks the JWT. |

### User login

- Login is `/api/v1/auth/login`. It issues an access token and a refresh token, with longer lifetimes when remember-me is set.
- **One session per user:** the session ID is stored in `users.current_session_id`.
- Login is locked after 5 failed attempts, for 30 minutes.
- The idle timeout is enforced only by the frontend.

### Authorization

- Access is permission-based. A user's role permissions become Spring authorities.
- Endpoints are protected with `@PreAuthorize("hasAuthority(...)")` and `@sentry.allowPermission(...)`.
- `PermissionScannerCommand` fills the `permissions` table at startup.

### Public endpoints

- `/api/v1/auth/*`, including login, register, reset and change-password
- Swagger
- `/api/v1/gepg/callback/*`
- `/api/v1/jasper/report/pdf`
- several `/mobile` reference endpoints
- `/api/v2/mobile/facilities/**` and `/api/v2/mobile/control-no-requests/**`

### Errors

- `GlobalExceptionHandler` maps exceptions to `{message, errorCode, path, status}`. It is only active under the **`production`** profile.
- Error codes are documented in `ERROR_CODES.md` in the backend repo.

---

## 9. Integrations

| System | Where | Notes |
|---|---|---|
| GePG | `GePGService`, `GePGCallbackController`, consumers | Points at the UAT URLs (`uat1.gepg.go.tz`). XML is signed with SHA256withRSA. Code 7101 = OK, 7303 = bad signature, 7283 = cancelled. |
| JasperServer | `JasperServerService` | Bill PDF report: `/reports/NemcGePG/GovernmentBill` |
| Superset | `SupersetService` | Guest tokens for embedded dashboards |
| mGov SMS | `SmsApiService` | HMAC-signed. Sender ID `NEMC`. Templates are in Swahili. |
| Email | `EmailServiceUtil` | Gmail SMTP. Templates are in `resources/email-templates`. |
| MMA (mobile app) | `mma/`, `NotifyMmaPaidBIlls` | Client and facility sync, bill creation, paid-bill callback to `mma.nemc.or.tz` |

---

## 10. Known issues and risks

Ordered by impact. The ✅ items were checked directly in the code.

### Critical

1. ✅ **Public endpoints can create bills.** `/api/v2/mobile/control-no-requests/**` and `/api/v2/mobile/facilities/**` need no login (`SecurityConfig.java:97-98`). `create-bill` accepts a caller-supplied `amount` and `billGenBy`, then sends the bill to GePG.
2. ✅ **Payment callbacks can overwrite each other.** `GePGCallbackController` uses a shared singleton `PaymentNotificationDto` (line ~76), so concurrent payment callbacks can overwrite each other's data.
3. ✅ **Payments can be silently lost.** The payment-callback error path still acks GePG with **7101 (success)** (line ~439), so GePG will not resend. In addition:
   - `PaymentConsumer` swallows `DataAccessException`.
   - Any amount paid marks the bill PAID, so partial payments count as full.
4. ✅ **Secrets are committed to git.** `application.propertiest` (a typo copy of the real file), `liquibase.properties` and `application.properties.sample` are tracked. Between them they contain the DB, JWT, GePG keystore, mGov API key, SMTP, Jasper and Superset credentials. `OAuth2ClientSeeder` hard-codes client secrets. **Rotate these credentials.**

### High

5. **Refresh tokens work as access tokens.** Both token types share the same key and have no type claim. A refresh token has no session ID, so it gets around logout and the one-session-per-user rule.
6. **`/api/v1/auth/change-password` is public.** It takes the username from the request body, and failed attempts are not counted toward the lockout.
7. ✅ **Scheduling cannot be turned off** with `app.scheduling.enabled` (`DemoApplication.java:14`).
8. **Retries never stop and can use the wrong path.** `BillSendToGepgConsumer` chooses the retry routing key from the retry counter, not from the bill type, so normal bills can be retried through the **reuse** endpoint. No queue has a maximum retry count.
9. **Cancellation state can drift from GePG.** A bill is marked CANCELLED when the request is approved, before GePG confirms. `/{id}/cancel` does not check that the request was approved.
10. **No XXE protection.** The XML parsers that read public callback input do not disable external entities.

### Medium

11. ✅ **Control-number SMS and email are never sent.** They go to `adhoc_sms_queue` and `adhoc_email_queue`, which have no consumer.
12. ✅ **Bulk SMS goes to one hardcoded phone**, 255762506012 (`SmsQueueConsumer.java:70`).
13. **Penalty rates disagree:**
    - 50% in `calculatePenaltyForAnnual`
    - 1% per day in `calculatePenalty`
    - 5% in `calculatePenaltyForAmount`
    - "5% per month" in the SMS text
14. **Hardcoded values:**
    - The deadline "31/12/2026" in the notification SMS
    - The MMA URL
    - The OAuth2 issuer `http://localhost:8080`
    - The HQ collection-center code
    - `createdBy=1L`
15. **Bill IDs and facility codes come from `count+1`**, so concurrent requests can produce the same code.
16. **Reconciliation data is stored but never matched** against payments.
17. **OAuth2 client checks are disabled:**
    - The OAuth2 signing key is regenerated at every startup, so a restart invalidates all client tokens.
    - `isAuthorizedClient` always returns `true`.
18. **CORS is configured in three conflicting places.** One allows `*` and another uses an allow-list with credentials.
19. **Tokens are logged.** `JwtAuthFilter` prints the full `Authorization` header to stdout.
20. **Large objects are never cleaned up**, and the bill status column contains values outside the enum (sections 3.3 and 3.6).

---

## 10a. Monthly bill renewal and penalties (the real process)

The monthly re-billing of unpaid annual fees is the most fragile part of the system. It was done a different way almost every month.

### The business rule, as applied in the data

This rule was checked against all 3,694 rows of `application.june_bills` and matched every one.

- The annual fee (the **principal**) is billed once per financial year (July–June). The bill is renewable, and its expiry is the end of a month.
- If the bill is still unpaid, a **new bill is issued every month** with the **same control number**:
  `amount = principal + (5% of principal × number of months overdue)`
  - The penalty is **simple, not compounding**. It is always 5% of the original principal, added as one `PENALTY` bill item per month.
  - Penalties start in the **month after** the start date. A start date of 2025-12-31 means the first penalty is in January. A start date of 2026-05-27 means the first penalty is in June.
  - Example: a principal of 1,000,000 that is unpaid in June has 6 penalties (Jan–Jun), so the bill is 1,300,000.
- **From July (new financial year)**, the new year's principal is added. The previous year's principal and its penalties are carried over (`CARRYOVER`), and the old principal keeps earning 5% per month.
- Each new bill expires at the end of its month. The `chk_bill_expiry` trigger enforces month-end expiry for renewable bills.

### How it was actually done, month by month (from the data)

| Month | Method | Evidence |
|---|---|---|
| Jan 2026 | Java `JobPenalty` (clones the bill and adds a penalty item) | 11,304 bills with `previous_bill_id`. Bill IDs use the Java style `NEMC-XX-yyMMdd-nnnn`. |
| Feb 2026 | Java `JobPenalty` | 284 renewals |
| Mar–Jun 2026 | **Manual SQL**, using staging tables in the `application` schema (`april_bills`, `may_bills`, `june_bills`…) | Bill IDs use the SQL style `NEMC-XX-yyyyMMdd-nnnnnnn`. Penalty items were inserted one at a time with `bill_item_penalty_amt` NULL. |
| Jul 2026 | **Nothing ran** | Only 205 bills, all new |
| Aug 2026 | Manual SQL (`august_for_billing`) | Uses `CARRYOVER` items and the new FY 2026/27 principal |

### The pieces that exist today, and why they don't work together

- **Database procedures (none scheduled; there is no pg_cron).** There are four overlapping procedures that set `renew_this_bill` and `bill_item_penalty_amt`, each with slightly different logic:
  - `run_bill_renewal()`
  - `semwa1()`
  - `sp_annual_bill_renewal_and_penalty()`
  - `sp_renew_bills_jan()`
- **Java `JobPenalty`** (`service/jobs/cloneBill/JobPenalty.java`, hourly at :15) clones every bill flagged `renew_this_bill`. Its problems:
  - It needs the DB procedures above to set the flags first, so it does nothing by itself.
  - The clone copies **all** old items, including earlier penalty items, and then adds one new penalty. The result is right only if the procedure ran exactly once per month. If it runs twice, a penalty is doubled. If a month is skipped, a penalty is missed.
  - It sets the new bill's status to `BILLED` before GePG confirms.
  - It does not mark the old bill `OBSOLETE`, so **4,886 control numbers each have more than one open, unpaid `BILLED` bill**.
  - Every item, including CARRYOVER, needs a `fee_penalty` row, or the whole bill fails.
- **`ReUseControlNo`** (every 15 min) sends bills flagged `reuse_control_number` to GePG as reuse submissions. The manual SQL months most likely relied on this flag.

### Replacement

A replacement for all of the above is in [`monthly_billing/`](monthly_billing/README.md). It is one SQL process run on the 1st of each month:

1. It prepares the month's bills with no GePG involvement.
2. A person reviews and approves them.
3. The existing `ReUseControlNo` job sends them to GePG.

It was tested on the local restore only.

---

## 11. Running locally safely

Before pointing the backend at the restored database:

1. **Expect the scheduled jobs to run.** The jobs in section 7 still run even with `app.scheduling.enabled=false`. Against a restore of production data they would call GePG (UAT), mGov SMS and MMA. To disable them, comment out `@EnableScheduling` in `DemoApplication`, or point those URLs at nothing.
2. Set `spring.datasource.*` in your local `application.properties` (gitignored) to your local user and the `mazingira` database. Keep `currentSchema=feesandcharges`.
3. RabbitMQ must be running locally (`127.0.0.1:5672`, user `guest`) or the app will fail to start its listeners.
4. Run with `./gradlew bootRun`. The app starts on `127.0.0.1:8083`.
5. The `dev` profile runs `BootstrapAdminCommand`, which creates a SYSTEM role and an admin user if they are missing.

### Useful queries

```sql
-- Bills by status
SELECT status, count(*) FROM feesandcharges.bill GROUP BY 1 ORDER BY 2 DESC;

-- A facility's bills and payment state
SELECT b.bill_id, b.control_number, b.status, b.bill_amt, b.is_paid
FROM feesandcharges.bill b
JOIN feesandcharges.bill_facility bf ON bf.bill = b.id
WHERE bf.facility = :facility_id;

-- Unprocessed payment inbox rows
SELECT * FROM feesandcharges.payment_inbox WHERE processed = false ORDER BY id DESC;

-- Read a stored GePG request XML
SELECT convert_from(lo_get(xml::oid), 'UTF8')
FROM feesandcharges.normal_bill_control_number_request_xml
WHERE bill = :bill_id;
```
