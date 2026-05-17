# `sql/` — diagnostic queries for the Engicon salary reallocation report

## `IS_EngiconSalaryReallocation.sql`

Read-only T-SQL translation of the X++ data provider class
`IS_EngiconSalaryReallocationDP` (see `../IS_EngiconSalaryReallocationDP.txt`).
Targets AxDB on SQL Server.

### Parameters

| Name                      | Type            | Default        | Notes                                                                                |
|---------------------------|-----------------|----------------|--------------------------------------------------------------------------------------|
| `@DataAreaId`             | `NVARCHAR(4)`   | `N'ENGJ'`      | AX legal entity (filters AX-side tables: timesheets, projects, resources).           |
| `@CompanyCode`            | `NVARCHAR(20)`  | `N'C01'`       | Payroll company code (`INS_PAYROLLEMPLTRANS.COMPANYCODE`). **Not** the same as `@DataAreaId` on this deployment. |
| `@FromDate`               | `DATE`          | `'2026-02-01'` | Window start (inclusive). Payroll uses `YEAR`/`MONTH` of `@FromDate`.                |
| `@ToDate`                 | `DATE`          | `'2026-02-28'` | Window end (inclusive).                                                              |
| `@ApprovalStatus`         | `INT`           | `6`            | `TSAppStatus`; `6` = Posted on this deployment's custom extension (standard enum stops at 5). |
| `@WorkerPersonnelNumber`  | `NVARCHAR(25)`  | `NULL`         | Optional filter; `NULL` = all workers.                                               |
| `@ProjId`                 | `NVARCHAR(20)`  | `NULL`         | Optional filter; `NULL` = all projects.                                              |

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
| 6 | `INS_PAYROLLEMPLTRANS.COMPANYCODE` is a payroll-specific code (e.g. `C01`), not equal to `@DataAreaId` (`ENGJ`); use the separate `@CompanyCode` parameter | Applied  |
| 7 | `TSTIMESHEETTABLE.APPROVALSTATUS = 6` represents the 'Posted' state on this deployment's custom `TSAppStatus` enum (standard enum stops at 5)            | Applied  |

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
catalog on **2026-05-17**:
- STEP 0 surfaced 13 identifier mismatches; all corrected.
- `RESOURCEVIEW` (view) confirmed as the physical backing for X++
  `ResourceView` via `INFORMATION_SCHEMA.TABLES` discovery.
- Data-shape diagnostic (5 probe queries) surfaced two further
  facts: `APPROVALSTATUS = 6` is Posted (custom enum extension), and
  `INS_PAYROLLEMPLTRANS.COMPANYCODE` uses payroll codes like `C01`
  rather than `ENGJ`. Both are now parameterised at the top of the
  script with sensible defaults.
