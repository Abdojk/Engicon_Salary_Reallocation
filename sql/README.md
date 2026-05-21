# `sql/` — Engicon salary reallocation report query

## `IS_EngiconSalaryReallocation.sql`

A plain, read-only T-SQL translation of the X++ data provider class
`IS_EngiconSalaryReallocationDP` (see `../IS_EngiconSalaryReallocationDP.txt`).
Run it against AxDB on SQL Server and it returns the report rows
directly — one `SELECT`, one result set.

### Parameters

Edit the `DECLARE` block at the top of the script before running.

| Name                      | Type            | Default        | Notes                                                                          |
|---------------------------|-----------------|----------------|--------------------------------------------------------------------------------|
| `@DataAreaId`             | `NVARCHAR(4)`   | `N'ENGJ'`      | AX legal entity (filters timesheets, projects, resources).                     |
| `@CompanyCode`            | `NVARCHAR(20)`  | `N'C01'`       | Payroll company code (`INS_PAYROLLEMPLTRANS.COMPANYCODE`).                      |
| `@FromDate`               | `DATE`          | `'2026-02-01'` | Window start (inclusive). Payroll uses the `YEAR`/`MONTH` of `@FromDate`.       |
| `@ToDate`                 | `DATE`          | `'2026-02-28'` | Window end (inclusive).                                                        |
| `@ApprovalStatus`         | `INT`           | `6`            | Timesheet `TSAppStatus`.                                                       |
| `@WorkerPersonnelNumber`  | `NVARCHAR(25)`  | `NULL`         | Optional filter; `NULL` = all workers.                                         |
| `@ProjId`                 | `NVARCHAR(20)`  | `NULL`         | Optional filter; `NULL` = all projects.                                        |

### Result set

One row per `(PersonnelNumber, ProjId, TransCode)`:
`PersonnelNumber`, `WorkerName`, `ProjId`, `ProjName`, `ProjGroupId`,
`ProjectHours`, `TotalHours`, `TransCode`, `TransCodeName`, `TransAmount`,
`ActualAmount`, `StandardAmount`. The `ActualAmount` / `StandardAmount`
formulae are taken verbatim from the X++ class.

### Notes

- `@CompanyCode` is **not** the same as `@DataAreaId` on this deployment:
  payroll rows use a code like `C01`, while AX-side tables use `ENGJ`.
- `@ApprovalStatus = 6` is the 'Posted' state on this deployment's custom
  `TSAppStatus` enum extension (the standard enum stops at 5).

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
