# PROMPT — Translate `IS_EngiconSalaryReallocationDP` (X++) into a parameterised T-SQL diagnostic script for AxDB

> Paste the contents of this file into a Claude Code session, or pass it as a task
> instruction. The script you produce will be executed read-only against a live
> AxDB (SQL Server) instance, so correctness is non-negotiable.

---

## 1. ROLE

You are a senior Dynamics 365 Finance & Operations engineer who is fluent in
both X++ and T-SQL, and who has hands-on experience reading the physical AxDB
schema on SQL Server. You write read-only diagnostic queries that finance
controllers run to reconcile in-application reports against the underlying
data. You verify every identifier you emit against the live catalog before
committing to a final query — you do not infer columns from documentation,
prior knowledge, or pattern-matching.

---

## 2. OBJECTIVE

Translate the X++ data provider class `IS_EngiconSalaryReallocationDP`
(embedded verbatim in section 10) into a single, parameterised, **read-only**
T-SQL script that:

1. Targets AxDB on SQL Server.
2. Replicates the class's logic step by step:
   - Per-worker / per-project timesheet hour accumulation from
     `TSTimesheetTable` → `TSTimesheetLine` → `TSTimesheetLineWeek`
     (with day-level flattening of the `Hours1..Hours7` array across the
     `[fromDate, toDate]` window).
   - Per-worker payroll cost aggregation from `INS_PayrollEmplTrans`
     for `Year = YEAR(fromDate)` and `Month = MONTH(fromDate)`, grouped
     by `TransCode`, summing `CostAmount` where `ProjectCost <> 0`.
   - The `ActualAmount` and `StandardAmount` formulae, taken **verbatim**
     from the X++ class (see section 10 — do not rewrite, simplify, or
     re-interpret them).
3. Emits one row per `(PersonnelNumber, ProjId, TransCode)` combination,
   matching the columns the class writes into
   `IS_EngiconSalaryReallocationTmp` (`PersonnelNumber`, `WorkerName`,
   `ProjId`, `ProjName`, `ProjGroupId`, `ProjectHours`, `TotalHours`,
   `TransCode`, `TransCodeName`, `TransAmount`, `ActualAmount`,
   `StandardAmount`).
4. Is parameterised at the top of the script for:
   - `@DataAreaId NVARCHAR(4)` — default `N'ENGJ'`
   - `@FromDate DATE`
   - `@ToDate DATE`
   - `@ApprovalStatus INT` — corresponds to `TSAppStatus`
   - `@WorkerPersonnelNumber NVARCHAR(25) = NULL` — optional filter
   - `@ProjId NVARCHAR(20) = NULL` — optional filter

---

## 3. CONTEXT

### 3.1 AxDB table topology relevant to this translation

| X++ table                       | AxDB physical table                  | Notes                                                                 |
|---------------------------------|--------------------------------------|-----------------------------------------------------------------------|
| `TSTimesheetTable`              | `TSTIMESHEETTABLE`                   | Filter on `APPROVALSTATUS` and `DATAAREAID`.                          |
| `TSTimesheetLine`               | `TSTIMESHEETLINE`                    | Joined via `TIMESHEETNBR`. Carries `PROJID`, `RESOURCE`, `DATAAREAID`. |
| `TSTimesheetLineWeek`           | `TSTIMESHEETLINEWEEK`                | Joined via `TSTIMESHEETLINE = TSTIMESHEETLINE.RECID`. Holds `DAYFROM` and the `HOURS1`..`HOURS7` array as flattened columns. |
| `ResourceView` (X++)            | Backed by `RESOURCE_` (physical)     | `RESOURCEID`, `RESOURCECOMPANYID`, `RECID`. See caveat in section 7.  |
| `HcmWorker`                     | `HCMWORKER`                          | `PERSONNELNUMBER`, `RECID`. Worker name via `DIRPARTYTABLE`/`HCMWORKER` join (see caveat).                                |
| `ProjTable`                     | `PROJTABLE`                          | `PROJID`, `NAME`, `PROJGROUPID`, `DATAAREAID`.                        |
| `INS_PayrollEmplTrans`          | `INS_PAYROLLEMPLTRANS`               | `PERSONNELNUMBER`, `YEAR`, `MONTH`, `TRANSCODE`, `COSTAMOUNT`, `PROJECTCOST`. **See CompanyCode caveat in section 7.** |
| `INS_PayrollTransInfoTable`     | `INS_PAYROLLTRANSINFOTABLE`          | `TRANSCODE`, `TRANSDESC`.                                             |
| `IS_EngiconSalaryReallocationTmp` | N/A — in-memory tmp table          | Do **not** write to it. Project final columns from a `SELECT`.        |

### 3.2 Valuation logic (from the class, do not re-derive)

For each `(worker, project, TransCode)` row:

```
projHours          = Σ TSTimesheetLineWeek.Hours[i] for each day i in week
                     where DayFrom+(i-1) ∈ [fromDate, toDate]
workerTotalHours   = Σ projHours over all the worker's projects in window
totalCategoryAmount= Σ CostAmount over the worker's INS_PayrollEmplTrans rows
                     for YEAR(fromDate) / MONTH(fromDate) with ProjectCost<>0
CostAmount         = Σ CostAmount for this (worker, TransCode)
hourRate           = ResourceFacade::getCostPrice(rv.RecId, toDate, 0)
                     — translate via ProjHourCostPrice (see caveat 7.4)

actualAmount       = (CostAmount / workerTotalHours) * projHours
                       when workerTotalHours <> 0, else 0
standardAmount     = projHours * hourRate * (CostAmount / totalCategoryAmount)
                       when totalCategoryAmount <> 0, else 0

ActualAmount   = ABS(actualAmount)
StandardAmount = ABS(standardAmount)
```

Rows where `workerTotalHours = 0` are skipped (the X++ class `continue`s on
the worker).

### 3.3 Governance rules

- The target database is **production AxDB**. The script you produce will
  be executed by a finance controller. It must be read-only.
- `WITH (NOLOCK)` is required on every table reference in the final
  `SELECT`s, so the diagnostic does not hold locks against the live
  workload. Do not use `READPAST` or other isolation hints.
- Wrap nothing in `BEGIN TRAN` / `COMMIT`. No DDL. No temp-table writes
  outside the script's own scope (you may use `#temp` tables or CTEs to
  stage intermediate aggregates).
- All filters on `DATAAREAID` use `@DataAreaId` and an explicit equality —
  never rely on a default company.

---

## 4. NON-NEGOTIABLE CONSTRAINTS

These rules override anything else in this prompt. If you cannot satisfy
them, stop and report the gap instead of proceeding.

1. **No Hallucinations.** Do not invent table names, column names, types,
   relationships, or default values. If you cannot verify an identifier
   against the live catalog, flag it and stop.
2. **No Assumptions.** Do not "guess" that a column is named what you
   expect from documentation, training data, or another company's AX
   deployment. AxDB is heavily customised; column casing, suffixes
   (`_`, `2_`), and physical layout differ between environments.
3. **Schema-First Rule.** Before you write the final `SELECT`, you must
   query `INFORMATION_SCHEMA.COLUMNS` (and `INFORMATION_SCHEMA.TABLES`)
   for every physical table you intend to reference, to confirm:
   - the table exists in the target database,
   - every column you use exists with the spelling and casing you use,
   - the type matches the way you use it (e.g. `INT` vs `NVARCHAR`).
   Emit the validation queries as the first executable block of the
   script, commented as `-- STEP 0: schema validation`.
4. **Read-Only Rule.** Zero `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `DROP`,
   `ALTER`, `CREATE` against any AxDB table. The only writes permitted
   are to local `#temp` tables or table variables you declare inside the
   script.
5. **Gap Flagging.** If any caveat in section 7 cannot be reconciled
   against the live catalog (e.g. `Resource_` does not exist in this
   environment), the script must `RAISERROR` with a clear message and
   stop, rather than silently producing wrong numbers.
6. **No Silent Fallbacks.** Do not coalesce a missing column to `NULL`
   "just in case". Either the column exists and is used, or the script
   stops and reports.

---

## 5. APPROVED SOURCE TIERS

When you need information beyond what is in this prompt, use sources in
this priority order. Always cite the tier you used in a comment next to
the line that depends on it.

- **Tier 1 — The live AxDB catalog** (`INFORMATION_SCHEMA.*`, `sys.*`).
  Authoritative for everything physical: table existence, column names,
  types, nullability, indexes.
- **Tier 2 — The X++ class embedded in section 10.** Authoritative for
  business logic: formulae, filters, ordering, edge-case handling.
- **Tier 3 — The pre-validated schema caveats in section 7.** Treat as
  facts unless the live catalog contradicts them; if it does, the catalog
  wins and you flag the discrepancy.
- **Tier 4 — Official Microsoft Learn documentation for D365FO / AxDB.**
  Useful for understanding standard tables (`HCMWORKER`, `PROJTABLE`).
  Never authoritative over the live catalog for physical layout.
- **Tier 5 — Anything else (blog posts, Stack Overflow, training-data
  recall).** Not approved as a source for identifiers. May be used for
  T-SQL syntax help only.

---

## 6. EXECUTION PLAN

Work through these steps in order. Do not skip ahead. Show your work as
you go.

1. **Read the source.** Read the X++ class in section 10 end-to-end.
   Build a short mental model of its three phases: (a) timesheet hours
   accumulation, (b) payroll cost aggregation, (c) per-row output with
   the two amount formulae.
2. **Enumerate physical tables.** List every AxDB physical table you
   intend to touch. Cross-reference against section 3.1.
3. **Validate the schema.** For each table from step 2, query
   `INFORMATION_SCHEMA.COLUMNS` for the columns you plan to use. Emit
   these validation queries at the top of the final script as
   `-- STEP 0: schema validation`. If any expected column is missing,
   the script must `RAISERROR` and stop.
4. **Reconcile caveats.** Walk through section 7. For each caveat,
   confirm it still holds in this catalog (or flag it). Adjust column
   names accordingly.
5. **Stage intermediates with CTEs.** Build the script as a chain of
   CTEs that mirror the X++ control flow:
   - `cteWeekDays` — flatten `HOURS1..HOURS7` into one row per
     `(TimesheetLine, Day, Hours)` and filter to `[@FromDate, @ToDate]`.
   - `cteProjectHours` — sum `Hours` per `(Worker, ProjId)`.
   - `cteWorkerTotalHours` — sum `Hours` per `Worker`.
   - `cteProjectTotalHours` — sum `Hours` per `ProjId`.
   - `ctePayrollByTransCode` — sum `CostAmount` per
     `(Worker, TransCode)` for the target month, with `ProjectCost<>0`.
   - `cteTotalCategoryAmount` — sum `CostAmount` per `Worker`.
   - `cteHourRate` — resolve the cost price per `Worker` at `@ToDate`
     using `ProjHourCostPrice` (see caveat 7.4).
6. **Final SELECT.** Cross-join project-hours rows with TransCode rows
   for the same worker, apply the optional `@WorkerPersonnelNumber` and
   `@ProjId` filters, compute `ActualAmount` and `StandardAmount`
   verbatim per section 3.2, and project the 12 output columns listed
   in section 2.3.
7. **Emit warnings as a second result set.** The X++ class accumulates
   a `warningList` (zero cost price, no payroll transactions, missing
   resource). Reproduce this as a second `SELECT` result set after the
   main one, with columns `(PersonnelNumber, Warning)`.
8. **Self-review.** Re-read the X++ formulae against your script line
   by line. Confirm `ABS()` is applied to the final amounts. Confirm
   the `workerTotalHours = 0` skip is preserved.

---

## 7. KNOWN SCHEMA CAVEATS (pre-validated on this AxDB)

These have been confirmed in prior sessions on this exact deployment.
Use them as your starting point, but **still re-verify with section 6
step 3** — if the catalog disagrees, the catalog wins and you flag it.

### 7.1 `INS_PayrollEmplTrans` has a `CompanyCode` filter

The `INS_PAYROLLEMPLTRANS` table on this deployment carries a
`COMPANYCODE` column that is **not** equivalent to `DATAAREAID`. Filter
on `COMPANYCODE = @DataAreaId` (confirmed for `ENGJ`). Do not rely on
`DATAAREAID` alone for this table.

### 7.2 `Resource_` is the physical name for `ResourceView`

The X++ `ResourceView` is backed physically by the table `RESOURCE_`
(note the trailing underscore). Use `RESOURCE_` in `FROM` clauses.
Columns of interest: `RECID`, `RESOURCEID`, `RESOURCECOMPANYID`,
`PERSONNELNUMBER`.

### 7.3 `Hours[i]` flattens to `HOURS1`..`HOURS7` on `TSTimesheetLineWeek`

The X++ array `tsWeek.Hours[i]` (1-indexed) maps to seven physical
columns on `TSTIMESHEETLINEWEEK`: `HOURS1`, `HOURS2`, `HOURS3`,
`HOURS4`, `HOURS5`, `HOURS6`, `HOURS7`. Day `i` corresponds to
`DAYFROM + (i-1)`. Use a `CROSS APPLY (VALUES ...)` or `UNPIVOT` to
flatten into one row per day, then filter by `[@FromDate, @ToDate]`.

### 7.4 `ResourceFacade::getCostPrice` ≈ `ProjHourCostPrice` lookup

The X++ call `ResourceFacade::getCostPrice(rv.RecId, toDate, 0)`
resolves on this deployment to a row from `PROJHOURCOSTPRICE` where:
- the worker matches via the resource's `PERSONNELNUMBER`,
- `DATAAREAID = @DataAreaId`,
- `FROMDATE <= @ToDate` (pick the latest such `FROMDATE`),
- `COSTPRICE` is the value used.

Use the **`FROMDATE`** column on `PROJHOURCOSTPRICE` as the effective
date (not `TRANSDATE`). Round to 3 decimal places to match the X++
`round(hourRate, 0.001)`.

---

## 8. OUTPUT FORMAT

Deliver, in this order:

1. **The final T-SQL script**, saved to a new file in this repository
   at `sql/IS_EngiconSalaryReallocation.sql`. The script must be
   self-contained and runnable as-is against AxDB with only the
   parameter values changed.
2. **A short README section** appended to `sql/README.md` (create the
   file if it does not exist), documenting:
   - the parameters and their defaults,
   - the two result sets (main + warnings),
   - which caveats from section 7 were confirmed live and which (if
     any) required adjustment,
   - the date you validated the schema.
3. **A summary message in chat** of no more than 200 words covering:
   what you produced, which caveats held, any gaps you flagged, and
   the exact commands the user needs to run the script.

Do not produce a pull request. Commit to `claude/dp-class-to-sql-d7ett`
and push. Do not open a PR unless the user explicitly asks.

---

## 9. TONE & LANGUAGE

- Write SQL in upper-case keywords, lower-case identifiers preserved as
  they appear in the catalog (AxDB column casing is typically upper —
  match what `INFORMATION_SCHEMA` returns).
- Comment each CTE with one short line explaining which X++ step it
  mirrors (e.g. `-- mirrors the projectTotalHours map`).
- Do not add commentary in the SQL that describes the obvious. No
  banner headers, no ASCII art, no "Author / Date / Version" blocks.
- In chat replies, be terse and factual. Lead with what you did, then
  what's outstanding. No marketing language.

---

## 10. SOURCE MATERIAL — `IS_EngiconSalaryReallocationDP` (verbatim)

```xpp
[SRSReportParameterAttribute(classStr(IS_EngiconSalaryReallocationContract))]
class IS_EngiconSalaryReallocationDP extends SrsReportDataProviderBase
{
    IS_EngiconSalaryReallocationTmp tmpTable;
    IS_EngiconSalaryReallocationContract contract;
    List warningList = new List(Types::String);
    public void processReport()
    {
        contract = this.parmDataContract();
        this.generateReportData();
        str msg;
        ListEnumerator le = warningList.getEnumerator();

        while (le.moveNext())
        {
            msg += le.current() + "\n";
        }

        if (msg)
        {
            checkFailed(msg);
        }
    }

    private void generateReportData()
    {
        delete_from tmpTable;

        TransDate fromDate = contract.parmFromDate();
        TransDate toDate   = contract.parmToDate();

        TSAppStatus appStatus=contract.parmStatus();


        boolean isWorkerSelected  = contract.parmWorker() != 0;
        boolean isProjectSelected = contract.parmProjId() != '';

        if (!fromDate || !toDate)
            throw error("Please select From date and To date.");

        if (fromDate > toDate)
            throw error("From date cannot be greater than To date.");

        if ((toDate - fromDate) > 366)
            throw error("Date range cannot exceed one year.");

        //if (!isWorkerSelected && !isProjectSelected)
        //    throw error("You must select either Worker or Project.");

        //if (!isWorkerSelected)
        //warningList.addEnd("Running report for all workers may take longer time.");

        HcmWorker worker;
        if (isWorkerSelected)
        {
            worker = HcmWorker::find(contract.parmWorker());
            if (!worker.RecId)
                throw error("Selected worker not found.");
        }

        Map transNameMap = new Map(Types::String, Types::String);
        INS_PayrollTransInfoTable transInfo;

        while select transInfo
        {
            transNameMap.insert(transInfo.TransCode, transInfo.TransDesc);
        }

        Map workerProjectHours = new Map(Types::String, Types::Class);
        Map projectTotalHours  = new Map(Types::String, Types::Real);

        TSTimesheetTable     tsTable;
        TSTimesheetLine      tsLine;
        TSTimesheetLineWeek  tsWeek;
        ResourceView         rv;
        ProjTable projTable;

        while select tsTable
            where tsTable.ApprovalStatus==appStatus
        join rv
            where tsTable.Resource == rv.RecId
&& (!isWorkerSelected || rv.ResourceId == worker.PersonnelNumber)
        join tsLine
            where tsLine.TimesheetNbr == tsTable.TimesheetNbr
        join tsWeek
            where tsWeek.TSTimesheetLine == tsLine.RecId
&& tsWeek.DayFrom <= toDate
&& (tsWeek.DayFrom + 6) >= fromDate
        {
            str workerId = rv.ResourceId;
            ProjId projId = tsLine.ProjId;

            real projHours = 0;
            int i;
            TransDate currentDay;

            for (i = 1; i <= 7; i++)
            {
                currentDay = tsWeek.DayFrom + (i - 1);

                if (currentDay >= fromDate && currentDay <= toDate)
                {
                    projHours += tsWeek.Hours[i];
                }
            }

            projectTotalHours.insert(
                projId,
                projectTotalHours.exists(projId)
                    ? projectTotalHours.lookup(projId) + projHours
                    : projHours
            );

            Map projectMap;

            if (!workerProjectHours.exists(workerId))
            {
                projectMap = new Map(Types::String, Types::Real);
                workerProjectHours.insert(workerId, projectMap);
            }
            else
            {
                projectMap = workerProjectHours.lookup(workerId);
            }

            projectMap.insert(
                projId,
                projectMap.exists(projId)
                    ? projectMap.lookup(projId) + projHours
                    : projHours
            );
        }

        if (workerProjectHours.elements() == 0)
        {
            info(strFmt(
                "No approved timesheets were found for worker %1 (%2) within the selected date range.",
                worker.PersonnelNumber,
                worker.name()
            ));
        }

        MapIterator workerIter = new MapIterator(workerProjectHours);

        while (workerIter.more())
        {
            str workerId = workerIter.key();
            Map projectMap = workerIter.value();

            HcmWorker loopWorker = HcmWorker::findByPersonnelNumber(workerId);

            select firstOnly rv where rv.ResourceId == workerId
&& rv.ResourceCompanyId == curExt();
            if (!rv.RecId)
            {
                info(strFmt("Resource for worker %1 was not found in company %2.", workerId, curext()));
            }
            CostPrice hourRate = ResourceFacade::getCostPrice(rv.RecId, toDate, 0);
            hourRate = round(hourRate, 0.001);


            

            if (hourRate == 0)
            {
                info(strFmt("Cost price is zero for worker %1.", workerId));
                warningList.addEnd(strFmt("Cost price is zero for worker %1.", workerId));
            }

            real workerTotalHours = 0;
            MapIterator projectIter = new MapIterator(projectMap);

            while (projectIter.more())
            {
                workerTotalHours += projectIter.value();
                projectIter.next();
            }
            if (workerTotalHours == 0)
            {
                workerIter.next();
                continue;
            }

            Map categoryAmountMap = new Map(Types::String, Types::Real);
            AmountCur totalCategoryAmount = 0;

            INS_PayrollEmplTrans payrollTrans;
            while select payrollTrans
                where payrollTrans.PersonnelNumber == workerId
&& payrollTrans.Year  == year(fromDate)
&& payrollTrans.Month == mthOfYr(fromDate)
&& payrollTrans.ProjectCost != 0
            {

                //Modified from transamoubt to CostAmount
                if (!categoryAmountMap.exists(payrollTrans.TransCode))
                    categoryAmountMap.insert(payrollTrans.TransCode, payrollTrans.CostAmount);
                else
                    categoryAmountMap.insert(
                        payrollTrans.TransCode,
                        categoryAmountMap.lookup(payrollTrans.TransCode) + payrollTrans.CostAmount
                    );

                totalCategoryAmount += payrollTrans.CostAmount;
            }

            if (totalCategoryAmount == 0)
            {
                info(strFmt("No payroll transactions found for worker %1.", workerId));
                warningList.addEnd(strFmt("No payroll transactions found for worker %1.", workerId));
                //workerIter.next();
                //continue;
            }

            MapIterator categoryIter = new MapIterator(categoryAmountMap);

            while (categoryIter.more())
            {
                str transCode = categoryIter.key();
                real CostAmount = categoryIter.value();

                projectIter = new MapIterator(projectMap);

                while (projectIter.more())
                {
                    //if(totalCategoryAmount == 0 || workerTotalHours == 0)
                    //{
                    //    projectIter.next();  // ✅ move forward
                    //    continue;
                    //}
                    ProjId projId = projectIter.key();
                    real projHours = projectIter.value();

                    if (isProjectSelected && projId != contract.parmProjId())
                    {
                        projectIter.next();
                        continue;
                    }
                    select firstOnly projTable
                    where projTable.ProjId == projId;
                    real actualAmount;
                    if( workerTotalHours != 0)
                    {
                        actualAmount = (CostAmount / workerTotalHours) * projHours;
                    }
                    real standardAmount;
                    if(totalCategoryAmount != 0)// && workerTotalHours == 0)
                    {
                        standardAmount =projHours * hourRate * (CostAmount / totalCategoryAmount);
                    }
                    tmpTable.clear();
                    tmpTable.PersonnelNumber = workerId;
                    tmpTable.WorkerName      = loopWorker.name();
                    tmpTable.ProjId          = projId;
                    tmpTable.ProjectHours    = projHours;
                    tmpTable.TotalHours      = projectTotalHours.lookup(projId);
                    tmpTable.ProjName     = projTable.Name;
                    tmpTable.ProjGroupId  = projTable.ProjGroupId;

                    tmpTable.TransCode = transCode;
                    tmpTable.TransCodeName = transNameMap.exists(transCode)
                        ? transNameMap.lookup(transCode)
                        : transCode;

                    tmpTable.TransAmount    = CostAmount;
                    tmpTable.ActualAmount   = abs(actualAmount);
                    tmpTable.StandardAmount = abs(standardAmount);

                    tmpTable.insert();

                    projectIter.next();
                }

                categoryIter.next();
            }

            workerIter.next();
        }
    }

    [SRSReportDataSetAttribute(tableStr(IS_EngiconSalaryReallocationTmp))]
    public IS_EngiconSalaryReallocationTmp getTmp()
    {
        select * from tmpTable;
        return tmpTable;
    }

}
```

---

## 11. END OF PROMPT

When you finish, end your turn with a brief status: what file you wrote,
which caveats held, which (if any) failed schema validation, and the
commit hash you pushed. Do not open a pull request.
