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

### Schema caveats applied (live-catalog confirmed 2026-05-17)

| # | Caveat                                                                                                                            | Status   |
|---|-----------------------------------------------------------------------------------------------------------------------------------|----------|
| 1 | `INS_PAYROLLEMPLTRANS.COMPANYCODE = @DataAreaId` (not `DATAAREAID`)                                                               | Applied  |
| 2 | `RESOURCEVIEW` (view) is the physical name for X++ `ResourceView`; `RESOURCE_` does not exist on this deployment                  | Applied  |
| 3 | `TSTIMESHEETLINEWEEK` flattens `Hours[i]` to `HOURS, HOURS2_, HOURS3_, HOURS4_, HOURS5_, HOURS6_, HOURS7_` — day 1 has no suffix, days 2-7 use `_` | Applied  |
| 4 | `PROJHOURCOSTPRICE.TRANSDATE` is the effective-from column for the cost-price lookup (not `FROMDATE`)                             | Applied  |
| 5 | `TSTIMESHEETTABLE.RESOURCE_` and `PROJHOURCOSTPRICE.RESOURCE_` use the trailing-underscore rename for the reserved word `RESOURCE` | Applied  |

`STEP 0: schema validation` queries `INFORMATION_SCHEMA.COLUMNS` for every
identifier the script references and aborts with `THROW 50100` if any are
missing.

### Open item still pending live confirmation

- `HCMWORKER.PERSON` joining to `DIRPARTYTABLE.RECID` for the worker
  display name. The X++ calls `loopWorker.name()`, which resolves
  through `DirPartyTable.Name` on stock D365FO. `STEP 0` will surface
  this on the next run if the join columns are named differently.

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
each execution. Caveat list above reconciled against the live AxDB
catalog on **2026-05-17** — STEP 0 surfaced 13 mismatches versus the
initial pre-validated set; all 13 corrections have been applied and
the resource-view physical name (`RESOURCEVIEW`) was confirmed via a
discovery query against `INFORMATION_SCHEMA.TABLES`.
