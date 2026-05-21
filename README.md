# Engicon_Salary_Reallocation

A read-only T-SQL port of the Engicon salary-reallocation Dynamics 365
Finance & Operations report. The original report runs on the X++ data
provider class `IS_EngiconSalaryReallocationDP`; this repository contains
a plain SQL query that reproduces that logic so the report rows can be
pulled directly from `AxDB` (SQL Server) without running the report.

## Repository contents

| Path | Description |
|------|-------------|
| [`sql/IS_EngiconSalaryReallocation.sql`](sql/IS_EngiconSalaryReallocation.sql) | **The SQL query.** Read-only T-SQL translation of the X++ data provider class — a single `SELECT` returning the report rows. |
| [`sql/README.md`](sql/README.md) | Usage docs for the query — parameters, result set, and how to run. |
| [`IS_EngiconSalaryReallocationDP.txt`](IS_EngiconSalaryReallocationDP.txt) | The source X++ class the script was translated from. |
| [`PROMPT_DP_Class_to_SQL.md`](PROMPT_DP_Class_to_SQL.md) | The translation prompt/spec used to produce the script. |

## Quick start

In SSMS or Azure Data Studio, against the `AxDB` database:

1. Open [`sql/IS_EngiconSalaryReallocation.sql`](sql/IS_EngiconSalaryReallocation.sql).
2. Edit the `DECLARE` block at the top of the script (date window,
   `@DataAreaId`, `@CompanyCode`, optional worker/project filters).
3. Execute. The query is read-only — it reads AxDB with `WITH (NOLOCK)`
   and returns the report rows as a single result set.

See [`sql/README.md`](sql/README.md) for the full parameter reference and
schema notes.
