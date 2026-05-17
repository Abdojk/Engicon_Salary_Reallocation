# `sql/` — diagnostic queries for the Engicon salary reallocation report

## `IS_EngiconSalaryReallocation.sql`

Read-only T-SQL translation of the X++ data provider class
`IS_EngiconSalaryReallocationDP` (see `../IS_EngiconSalaryReallocationDP.txt`).
Targets AxDB on SQL Server.

### Parameters

| Name                      | Type            | Default      | Notes                                                  |
|---------------------------|-----------------|--------------|--------------------------------------------------------|
| `@DataAreaId`             | `NVARCHAR(4)`   | `N'ENGJ'`    | Legal entity / company.                                |
| `@FromDate`               | `DATE`          | `'2025-01-01'` | Window start (inclusive).                            |
| `@ToDate`                 | `DATE`          | `'2025-01-31'` | Window end (inclusive). Payroll uses YEAR/MONTH of `@FromDate`. |
| `@ApprovalStatus`         | `INT`           | `4`          | `TSAppStatus`; `4` = Approved on stock D365FO.        |
| `@WorkerPersonnelNumber`  | `NVARCHAR(25)`  | `NULL`       | Optional filter; `NULL` = all workers.                |
| `@ProjId`                 | `NVARCHAR(20)`  | `NULL`       | Optional filter; `NULL` = all projects.               |

### Result sets

1. **Main rows** — one per `(PersonnelNumber, ProjId, TransCode)` combination:
   `PersonnelNumber`, `WorkerName`, `ProjId`, `ProjName`, `ProjGroupId`,
   `ProjectHours`, `TotalHours`, `TransCode`, `TransCodeName`, `TransAmount`,
   `ActualAmount`, `StandardAmount`. Formulae taken verbatim from the X++
   class.
2. **Warnings** — `(PersonnelNumber, Warning)` for workers with zero cost
   price or no payroll transactions in the target month.

### Pre-validated schema caveats applied

The script is built on four caveats confirmed for this AxDB deployment:

| # | Caveat                                                                  | Status   |
|---|-------------------------------------------------------------------------|----------|
| 1 | `INS_PAYROLLEMPLTRANS.COMPANYCODE = @DataAreaId` (not `DATAAREAID`)     | Applied  |
| 2 | `RESOURCE_` is the physical name for X++ `ResourceView`                 | Applied  |
| 3 | `TSTIMESHEETLINEWEEK.HOURS1..HOURS7` flatten the `Hours[i]` array       | Applied  |
| 4 | `PROJHOURCOSTPRICE.FROMDATE` (not `TRANSDATE`) is the effective date    | Applied  |

`STEP 0: schema validation` queries `INFORMATION_SCHEMA.COLUMNS` for every
identifier the script references and aborts with `THROW 50100` if any are
missing. The user's first run will confirm or contradict these caveats.

### Open items to confirm on the live catalog

These are not pre-validated and `STEP 0` will surface them:

- `HCMWORKER.PERSON` joining to `DIRPARTYTABLE.RECID` for the worker
  display name — the X++ calls `loopWorker.name()`, which resolves
  through `DirPartyTable.Name` on stock D365FO.
- `PROJHOURCOSTPRICE.RESOURCE` as the foreign key to `RESOURCE_.RECID`.
  If this deployment uses a different name (e.g. `RESOURCEID`,
  `PERSONNELNUMBER`), `STEP 0` will abort with a clear message and the
  column reference will need to be adjusted.

### How to run

In SSMS / Azure Data Studio against the AxDB database:

```sql
USE AxDB;
GO

-- Edit the DECLARE block at the top of the script, then execute:
:r sql\IS_EngiconSalaryReallocation.sql
```

Or paste the script body directly and adjust the parameter values in
the `DECLARE` block.

### Validation date

Schema-first validation queries are embedded; the user runs them on
each execution. Caveat list above last reconciled against prior
session findings on **2026-05-17**.
