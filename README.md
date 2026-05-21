# Engicon_Salary_Reallocation

A read-only T-SQL diagnostic port of the Engicon salary-reallocation
Dynamics 365 Finance & Operations report. The original report runs on the
X++ data provider class `IS_EngiconSalaryReallocationDP`; this repository
contains a faithful T-SQL translation of that logic so the same numbers
can be inspected directly against `AxDB` (SQL Server) without running the
report.

## Repository contents

| Path | Description |
|------|-------------|
| [`sql/IS_EngiconSalaryReallocation.sql`](sql/IS_EngiconSalaryReallocation.sql) | **The SQL script.** Read-only T-SQL translation of the X++ data provider class. Emits two result sets: main rows and warnings. |
| [`sql/README.md`](sql/README.md) | Usage docs for the script — parameters, result sets, schema caveats, and how to run. |
| [`IS_EngiconSalaryReallocationDP.txt`](IS_EngiconSalaryReallocationDP.txt) | The source X++ class the script was translated from. |
| [`PROMPT_DP_Class_to_SQL.md`](PROMPT_DP_Class_to_SQL.md) | The translation prompt/spec used to produce the script. |

## Quick start

In SSMS or Azure Data Studio, against the `AxDB` database:

1. Open [`sql/IS_EngiconSalaryReallocation.sql`](sql/IS_EngiconSalaryReallocation.sql).
2. Edit the `DECLARE` block at the top of the script (date window,
   `@DataAreaId`, `@CompanyCode`, optional worker/project filters).
3. Execute. The script is read-only — it queries AxDB with `WITH (NOLOCK)`
   and writes only to local `#temp` tables.

See [`sql/README.md`](sql/README.md) for the full parameter reference and
schema notes.
