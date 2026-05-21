/* =====================================================================
   IS_EngiconSalaryReallocation — DIAGNOSTIC PACK (Sub-task A)
   ---------------------------------------------------------------------
   Purpose : discover the correct ApprovalStatus value and confirm every
             table/column name before the main replication script
             (IS_EngiconSalaryReallocation_v2.sql) is finalised.

   Read-only. Every statement is a SELECT. No DDL, no DML, no temp tables.
   Safe to run against a production AxDB.

   HOW TO USE
     Run each numbered section against the AxDB database and paste the
     result sets back. The main script cannot be finalised until:
       - Section 1  : the "Approved" ApprovalStatus integer is confirmed
       - Section 2  : TSTimesheetTable resource column is [Resource]
                      vs [Resource_]
       - Sections 3-8 : the remaining column names are confirmed

   Scope : legal entity ENGJ, payroll CompanyCode C01, February 2026.
   ===================================================================== */


/* ---------------------------------------------------------------------
   SECTION 1 — APPROVAL STATUS DISCOVERY
   ---------------------------------------------------------------------
   Counts timesheets and lines per ApprovalStatus for week records that
   overlap February 2026. The ApprovalStatus value with the highest
   TimesheetCount is the value the X++ class uses as its "Approved"
   filter. Do NOT assume the value is 4 or 6 — read it from this result.
   --------------------------------------------------------------------- */
SELECT
    tst.ApprovalStatus,
    COUNT(DISTINCT tst.TimesheetNbr) AS TimesheetCount,
    COUNT(DISTINCT tsl.RecId)        AS LineCount
FROM TSTimesheetTable tst
JOIN TSTimesheetLine     tsl  ON tsl.TimesheetNbr   = tst.TimesheetNbr
JOIN TSTimesheetLineWeek tslw ON tslw.TSTimesheetLine = tsl.RecId
WHERE tslw.DayFrom         <= '2026-02-28'
  AND DATEADD(day, 6, tslw.DayFrom) >= '2026-02-01'
GROUP BY tst.ApprovalStatus
ORDER BY TimesheetCount DESC;


/* ---------------------------------------------------------------------
   SECTION 2 — TSTimesheetTable RESOURCE COLUMN
   ---------------------------------------------------------------------
   "Resource" is a SQL Server reserved word; AX/D365 often stores it as
   Resource_. Confirm which form exists. Use exactly one in the main
   script.
   --------------------------------------------------------------------- */
SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'TSTimesheetTable'
  AND COLUMN_NAME IN ('Resource', 'Resource_');


/* ---------------------------------------------------------------------
   SECTION 3 — TSTimesheetLineWeek DAY-HOUR COLUMNS
   ---------------------------------------------------------------------
   Confirm the 7 day-hour columns and DayFrom exist with the expected
   names (day 1 = Hours, days 2-7 = Hours2_ .. Hours7_).
   --------------------------------------------------------------------- */
SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'TSTimesheetLineWeek'
  AND COLUMN_NAME IN (
      'DayFrom','Hours','Hours2_','Hours3_',
      'Hours4_','Hours5_','Hours6_','Hours7_'
  )
ORDER BY COLUMN_NAME;


/* ---------------------------------------------------------------------
   SECTION 4 — ProjHourCostPrice COLUMNS
   ---------------------------------------------------------------------
   Confirm the cost-price lookup columns: the effective-date column is
   TransDate (not FromDate); the resource key is Resource_; CategoryId
   is required for the getCostPrice(rv.RecId, toDate, 0) replication.
   Full column list returned so any naming surprise is visible.
   --------------------------------------------------------------------- */
SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'ProjHourCostPrice'
ORDER BY ORDINAL_POSITION;


/* ---------------------------------------------------------------------
   SECTION 5 — ResourceView TABLE / COLUMNS
   ---------------------------------------------------------------------
   5a: confirm the object exists and whether it is a table or a view.
   5b: confirm RecId, ResourceId, ResourceCompanyId.
   --------------------------------------------------------------------- */
SELECT TABLE_NAME, TABLE_TYPE
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME = 'ResourceView';

SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'ResourceView'
  AND COLUMN_NAME IN ('RecId', 'ResourceId', 'ResourceCompanyId')
ORDER BY COLUMN_NAME;


/* ---------------------------------------------------------------------
   SECTION 6 — INS_PayrollEmplTrans COLUMNS
   ---------------------------------------------------------------------
   Confirm there is NO DataAreaId column (SaveDataPerCompany = No) and
   that CompanyCode, Year, Month, TransCode, CostAmount, ProjectCost and
   PersonnelNumber exist. Full column list returned.
   --------------------------------------------------------------------- */
SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'INS_PayrollEmplTrans'
ORDER BY ORDINAL_POSITION;


/* ---------------------------------------------------------------------
   SECTION 7 — INS_PayrollTransInfoTable COLUMNS
   --------------------------------------------------------------------- */
SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'INS_PayrollTransInfoTable'
ORDER BY ORDINAL_POSITION;


/* ---------------------------------------------------------------------
   SECTION 8 — ProjTable / HcmWorker / DirPartyTable COLUMNS
   ---------------------------------------------------------------------
   8a: ProjTable — ProjId, Name, ProjGroupId, DataAreaId.
   8b: HcmWorker — PersonnelNumber, RecId, Person, and whether a
       DataAreaId column exists (standard D365 HcmWorker is global).
   8c: DirPartyTable — RecId, Name (worker display name source).
   --------------------------------------------------------------------- */
SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'ProjTable'
  AND COLUMN_NAME IN ('ProjId', 'Name', 'ProjGroupId', 'DataAreaId')
ORDER BY COLUMN_NAME;

SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'HcmWorker'
  AND COLUMN_NAME IN ('PersonnelNumber', 'RecId', 'Person', 'DataAreaId')
ORDER BY COLUMN_NAME;

SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'DirPartyTable'
  AND COLUMN_NAME IN ('RecId', 'Name')
ORDER BY COLUMN_NAME;


/* ---------------------------------------------------------------------
   SECTION 9 — INS BY-TRANSCODE DATA-SHAPE PROBE
   ---------------------------------------------------------------------
   Expected to match Source 2: 8 TransCodes plus TC32, 977 data rows,
   SUM(ABS) per group totalling 633,766.560. The SUBTOTAL row is
   surfaced separately (TransCode NULL or blank).
   --------------------------------------------------------------------- */
SELECT
    p.TransCode,
    COUNT(*)                              AS RowCnt,
    SUM(p.CostAmount)                     AS SumCostAmount,
    ABS(SUM(p.CostAmount))                AS AbsSumCostAmount
FROM INS_PayrollEmplTrans p
WHERE p.CompanyCode = 'C01'
  AND p.[Year]      = 2026
  AND p.[Month]     = 2
  AND p.ProjectCost <> 0
GROUP BY p.TransCode
ORDER BY p.TransCode;

-- 9b: isolate the SUBTOTAL / blank-TransCode row(s) that must be excluded
SELECT
    p.TransCode,
    COUNT(*)          AS RowCnt,
    SUM(p.CostAmount) AS SumCostAmount
FROM INS_PayrollEmplTrans p
WHERE p.CompanyCode = 'C01'
  AND p.[Year]      = 2026
  AND p.[Month]     = 2
  AND p.ProjectCost <> 0
  AND (p.TransCode IS NULL OR LTRIM(RTRIM(p.TransCode)) = '')
GROUP BY p.TransCode;


/* ---------------------------------------------------------------------
   SECTION 10 — WORKER 2335 TIMESHEET PROBE
   ---------------------------------------------------------------------
   TransCode 32 (PersonnelNumber 2335) appears in INS but is expected to
   be ABSENT from the main script output, because worker 2335 has no
   approved timesheets in February 2026. This lists 2335's timesheet
   week records by ApprovalStatus so that absence can be confirmed.
   --------------------------------------------------------------------- */
SELECT
    tst.ApprovalStatus,
    COUNT(DISTINCT tst.TimesheetNbr) AS TimesheetCount,
    COUNT(DISTINCT tslw.RecId)       AS WeekRecordCount
FROM TSTimesheetTable tst
JOIN ResourceView        rv   ON rv.RecId = tst.Resource_      -- adjust to [Resource] if Section 2 says so
JOIN TSTimesheetLine     tsl  ON tsl.TimesheetNbr   = tst.TimesheetNbr
JOIN TSTimesheetLineWeek tslw ON tslw.TSTimesheetLine = tsl.RecId
WHERE rv.ResourceId = '2335'
  AND tslw.DayFrom         <= '2026-02-28'
  AND DATEADD(day, 6, tslw.DayFrom) >= '2026-02-01'
GROUP BY tst.ApprovalStatus
ORDER BY tst.ApprovalStatus;

/* ===================================================================== */
