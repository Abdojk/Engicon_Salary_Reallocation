/* =====================================================================
   IS_EngiconSalaryReallocation — diagnostic translation of the X++
   data provider class IS_EngiconSalaryReallocationDP into read-only
   T-SQL for AxDB (SQL Server).

   Read-only. WITH (NOLOCK) on every AxDB table. No DDL, no DML against
   AxDB tables. Writes only to local #temp tables inside this script.

   Emits two result sets:
     1) main rows — one per (PersonnelNumber, ProjId, TransCode)
     2) warnings — workers with zero cost price or no payroll trans.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

-- ---------------------------------------------------------------------
-- Parameters (edit per run)
-- ---------------------------------------------------------------------
DECLARE @DataAreaId             NVARCHAR(4)   = N'ENGJ';
DECLARE @CompanyCode            NVARCHAR(20)  = N'C01';       -- INS_PAYROLLEMPLTRANS.COMPANYCODE; not the same as @DataAreaId
DECLARE @FromDate               DATE          = '2026-02-01';
DECLARE @ToDate                 DATE          = '2026-02-28';
DECLARE @ApprovalStatus         INT           = 6;            -- 6 = Posted on this AxDB's custom TSAppStatus extension
DECLARE @WorkerPersonnelNumber  NVARCHAR(25)  = NULL;         -- optional
DECLARE @ProjId                 NVARCHAR(20)  = NULL;         -- optional

-- ---------------------------------------------------------------------
-- Date guards (mirror the X++ guards in generateReportData)
-- ---------------------------------------------------------------------
IF @FromDate IS NULL OR @ToDate IS NULL
    THROW 50000, 'Please select From date and To date.', 1;

IF @FromDate > @ToDate
    THROW 50001, 'From date cannot be greater than To date.', 1;

IF DATEDIFF(DAY, @FromDate, @ToDate) > 366
    THROW 50002, 'Date range cannot exceed one year.', 1;

-- ---------------------------------------------------------------------
-- STEP 0: schema validation
--   Verify every physical table/column this script depends on exists in
--   the current database. If anything is missing, abort with a clear
--   message rather than silently producing wrong numbers.
-- ---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Required') IS NOT NULL DROP TABLE #Required;
CREATE TABLE #Required (TableName SYSNAME NOT NULL, ColumnName SYSNAME NOT NULL);

INSERT INTO #Required (TableName, ColumnName) VALUES
 ('TSTIMESHEETTABLE',         'TIMESHEETNBR'),
 ('TSTIMESHEETTABLE',         'APPROVALSTATUS'),
 ('TSTIMESHEETTABLE',         'RESOURCE_'),
 ('TSTIMESHEETTABLE',         'DATAAREAID'),
 ('TSTIMESHEETLINE',          'TIMESHEETNBR'),
 ('TSTIMESHEETLINE',          'RECID'),
 ('TSTIMESHEETLINE',          'PROJID'),
 ('TSTIMESHEETLINE',          'DATAAREAID'),
 ('TSTIMESHEETLINEWEEK',      'TSTIMESHEETLINE'),
 ('TSTIMESHEETLINEWEEK',      'DAYFROM'),
 ('TSTIMESHEETLINEWEEK',      'HOURS'),
 ('TSTIMESHEETLINEWEEK',      'HOURS2_'),
 ('TSTIMESHEETLINEWEEK',      'HOURS3_'),
 ('TSTIMESHEETLINEWEEK',      'HOURS4_'),
 ('TSTIMESHEETLINEWEEK',      'HOURS5_'),
 ('TSTIMESHEETLINEWEEK',      'HOURS6_'),
 ('TSTIMESHEETLINEWEEK',      'HOURS7_'),
 ('RESOURCEVIEW',             'RECID'),
 ('RESOURCEVIEW',             'RESOURCEID'),
 ('RESOURCEVIEW',             'RESOURCECOMPANYID'),
 ('HCMWORKER',                'PERSONNELNUMBER'),
 ('HCMWORKER',                'RECID'),
 ('HCMWORKER',                'PERSON'),
 ('DIRPARTYTABLE',            'RECID'),
 ('DIRPARTYTABLE',            'NAME'),
 ('PROJTABLE',                'PROJID'),
 ('PROJTABLE',                'NAME'),
 ('PROJTABLE',                'PROJGROUPID'),
 ('PROJTABLE',                'DATAAREAID'),
 ('INS_PAYROLLEMPLTRANS',     'PERSONNELNUMBER'),
 ('INS_PAYROLLEMPLTRANS',     'YEAR'),
 ('INS_PAYROLLEMPLTRANS',     'MONTH'),
 ('INS_PAYROLLEMPLTRANS',     'TRANSCODE'),
 ('INS_PAYROLLEMPLTRANS',     'COSTAMOUNT'),
 ('INS_PAYROLLEMPLTRANS',     'PROJECTCOST'),
 ('INS_PAYROLLEMPLTRANS',     'COMPANYCODE'),
 ('INS_PAYROLLTRANSINFOTABLE','TRANSCODE'),
 ('INS_PAYROLLTRANSINFOTABLE','TRANSDESC'),
 ('PROJHOURCOSTPRICE',        'COSTPRICE'),
 ('PROJHOURCOSTPRICE',        'TRANSDATE'),
 ('PROJHOURCOSTPRICE',        'RESOURCE_'),
 ('PROJHOURCOSTPRICE',        'DATAAREAID');

DECLARE @missing NVARCHAR(MAX) =
    (SELECT STRING_AGG(r.TableName + N'.' + r.ColumnName, N', ')
     FROM #Required AS r
     WHERE NOT EXISTS (
         SELECT 1
         FROM INFORMATION_SCHEMA.COLUMNS AS c
         WHERE UPPER(c.TABLE_NAME)  = r.TableName
           AND UPPER(c.COLUMN_NAME) = r.ColumnName
     ));

IF @missing IS NOT NULL AND LEN(@missing) > 0
BEGIN
    DECLARE @msg NVARCHAR(MAX) =
        N'Schema validation failed. Missing identifiers: ' + @missing;
    THROW 50100, @msg, 1;
END;

-- ---------------------------------------------------------------------
-- STEP 1: flatten tsWeek.Hours[1..7] into one row per day, filter to
--         [@FromDate, @ToDate] and approval status (mirrors the week
--         join with the per-day for-loop in the X++ class).
-- ---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#WeekDays') IS NOT NULL DROP TABLE #WeekDays;
SELECT
    rv.RESOURCEID                              AS WorkerId,
    tsLine.PROJID                              AS ProjId,
    DATEADD(DAY, d.DayOffset, tsWeek.DAYFROM)  AS WorkDay,
    d.Hours                                    AS Hours
INTO #WeekDays
FROM TSTIMESHEETTABLE     AS ts     WITH (NOLOCK)
JOIN RESOURCEVIEW         AS rv     WITH (NOLOCK)
    ON  rv.RECID            = ts.RESOURCE_
    AND rv.RESOURCECOMPANYID = @DataAreaId
JOIN TSTIMESHEETLINE      AS tsLine WITH (NOLOCK)
    ON  tsLine.TIMESHEETNBR = ts.TIMESHEETNBR
    AND tsLine.DATAAREAID   = ts.DATAAREAID
JOIN TSTIMESHEETLINEWEEK  AS tsWeek WITH (NOLOCK)
    ON  tsWeek.TSTIMESHEETLINE = tsLine.RECID
CROSS APPLY (VALUES
    (0, tsWeek.HOURS),
    (1, tsWeek.HOURS2_),
    (2, tsWeek.HOURS3_),
    (3, tsWeek.HOURS4_),
    (4, tsWeek.HOURS5_),
    (5, tsWeek.HOURS6_),
    (6, tsWeek.HOURS7_)
) AS d (DayOffset, Hours)
WHERE ts.APPROVALSTATUS = @ApprovalStatus
  AND ts.DATAAREAID     = @DataAreaId
  AND tsWeek.DAYFROM   <= @ToDate
  AND DATEADD(DAY, 6, tsWeek.DAYFROM) >= @FromDate
  AND DATEADD(DAY, d.DayOffset, tsWeek.DAYFROM) BETWEEN @FromDate AND @ToDate
  AND (@WorkerPersonnelNumber IS NULL OR rv.RESOURCEID = @WorkerPersonnelNumber);

-- ---------------------------------------------------------------------
-- STEP 2: per-(worker, project) hours  (mirrors projectMap.insert)
-- ---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#ProjectHours') IS NOT NULL DROP TABLE #ProjectHours;
SELECT WorkerId, ProjId, SUM(Hours) AS ProjHours
INTO   #ProjectHours
FROM   #WeekDays
GROUP BY WorkerId, ProjId;

-- ---------------------------------------------------------------------
-- STEP 3: per-project total hours across all selected workers
--         (mirrors projectTotalHours map)
-- ---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#ProjectTotalHours') IS NOT NULL DROP TABLE #ProjectTotalHours;
SELECT ProjId, SUM(Hours) AS TotalHours
INTO   #ProjectTotalHours
FROM   #WeekDays
GROUP BY ProjId;

-- ---------------------------------------------------------------------
-- STEP 4: per-worker total hours
--         (mirrors workerTotalHours; rows with sum=0 are skipped, see
--          the `continue` on workerTotalHours==0 in the X++ class)
-- ---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#WorkerTotalHours') IS NOT NULL DROP TABLE #WorkerTotalHours;
SELECT WorkerId, SUM(ProjHours) AS WorkerTotalHours
INTO   #WorkerTotalHours
FROM   #ProjectHours
GROUP BY WorkerId
HAVING SUM(ProjHours) <> 0;

-- ---------------------------------------------------------------------
-- STEP 5: per-(worker, TransCode) payroll cost for YEAR/MONTH of
--         @FromDate. CompanyCode filter per the pre-validated caveat.
--         (mirrors categoryAmountMap)
-- ---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#PayrollByTransCode') IS NOT NULL DROP TABLE #PayrollByTransCode;
SELECT
    p.PERSONNELNUMBER       AS WorkerId,
    p.TRANSCODE             AS TransCode,
    SUM(p.COSTAMOUNT)       AS CostAmount
INTO #PayrollByTransCode
FROM INS_PAYROLLEMPLTRANS AS p WITH (NOLOCK)
WHERE p.[YEAR]      = YEAR(@FromDate)
  AND p.[MONTH]     = MONTH(@FromDate)
  AND p.PROJECTCOST <> 0
  AND p.COMPANYCODE = @CompanyCode
GROUP BY p.PERSONNELNUMBER, p.TRANSCODE;

-- ---------------------------------------------------------------------
-- STEP 6: per-worker total payroll cost  (mirrors totalCategoryAmount)
-- ---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#TotalCategoryAmount') IS NOT NULL DROP TABLE #TotalCategoryAmount;
SELECT WorkerId, SUM(CostAmount) AS TotalCategoryAmount
INTO   #TotalCategoryAmount
FROM   #PayrollByTransCode
GROUP BY WorkerId;

-- ---------------------------------------------------------------------
-- STEP 7: per-worker hour rate at @ToDate, rounded to 0.001
--         (mirrors ResourceFacade::getCostPrice(rv.RecId, toDate, 0))
-- ---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#HourRate') IS NOT NULL DROP TABLE #HourRate;
SELECT
    rv.RESOURCEID AS WorkerId,
    ROUND(
        (SELECT TOP (1) phc.COSTPRICE
         FROM PROJHOURCOSTPRICE AS phc WITH (NOLOCK)
         WHERE phc.DATAAREAID = @DataAreaId
           AND phc.RESOURCE_  = rv.RECID
           AND phc.TRANSDATE <= @ToDate
         ORDER BY phc.TRANSDATE DESC),
    3) AS HourRate
INTO #HourRate
FROM RESOURCEVIEW AS rv WITH (NOLOCK)
WHERE rv.RESOURCECOMPANYID = @DataAreaId
  AND EXISTS (SELECT 1 FROM #WorkerTotalHours wth WHERE wth.WorkerId = rv.RESOURCEID);

-- ---------------------------------------------------------------------
-- STEP 8: TransCode → human-readable description
-- ---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#TransName') IS NOT NULL DROP TABLE #TransName;
SELECT ti.TRANSCODE AS TransCode, MAX(ti.TRANSDESC) AS TransDesc
INTO   #TransName
FROM   INS_PAYROLLTRANSINFOTABLE AS ti WITH (NOLOCK)
GROUP BY ti.TRANSCODE;

-- ---------------------------------------------------------------------
-- MAIN RESULT SET: one row per (PersonnelNumber, ProjId, TransCode)
--   ActualAmount   = ABS((CostAmount / workerTotalHours) * projHours)
--   StandardAmount = ABS(projHours * hourRate * (CostAmount / totalCategoryAmount))
-- ---------------------------------------------------------------------
SELECT
    ph.WorkerId                                                            AS PersonnelNumber,
    dp.NAME                                                                AS WorkerName,
    ph.ProjId,
    pt.NAME                                                                AS ProjName,
    pt.PROJGROUPID                                                         AS ProjGroupId,
    ph.ProjHours                                                           AS ProjectHours,
    pth.TotalHours                                                         AS TotalHours,
    ptc.TransCode,
    COALESCE(tn.TransDesc, ptc.TransCode)                                  AS TransCodeName,
    ptc.CostAmount                                                         AS TransAmount,
    ABS( (ptc.CostAmount / wth.WorkerTotalHours) * ph.ProjHours )          AS ActualAmount,
    CASE
        WHEN tca.TotalCategoryAmount IS NULL
          OR tca.TotalCategoryAmount = 0 THEN 0
        ELSE ABS(
                ph.ProjHours
              * ISNULL(hr.HourRate, 0)
              * (ptc.CostAmount / tca.TotalCategoryAmount)
             )
    END                                                                    AS StandardAmount
FROM      #ProjectHours        AS ph
JOIN      #WorkerTotalHours    AS wth ON wth.WorkerId = ph.WorkerId
JOIN      #PayrollByTransCode  AS ptc ON ptc.WorkerId = ph.WorkerId
JOIN      #TotalCategoryAmount AS tca ON tca.WorkerId = ph.WorkerId
JOIN      #ProjectTotalHours   AS pth ON pth.ProjId   = ph.ProjId
LEFT JOIN #HourRate            AS hr  ON hr.WorkerId  = ph.WorkerId
LEFT JOIN #TransName           AS tn  ON tn.TransCode = ptc.TransCode
LEFT JOIN PROJTABLE            AS pt  WITH (NOLOCK)
       ON pt.PROJID     = ph.ProjId
      AND pt.DATAAREAID = @DataAreaId
LEFT JOIN HCMWORKER            AS w   WITH (NOLOCK)
       ON w.PERSONNELNUMBER = ph.WorkerId
LEFT JOIN DIRPARTYTABLE        AS dp  WITH (NOLOCK)
       ON dp.RECID = w.PERSON
WHERE (@ProjId IS NULL OR ph.ProjId = @ProjId)
ORDER BY ph.WorkerId, ph.ProjId, ptc.TransCode;

-- ---------------------------------------------------------------------
-- WARNINGS RESULT SET (mirrors warningList in the X++ class)
--   - Cost price is zero for worker
--   - No payroll transactions found for worker
-- ---------------------------------------------------------------------
SELECT PersonnelNumber, Warning
FROM (
    SELECT wth.WorkerId AS PersonnelNumber,
           N'Cost price is zero for worker ' + wth.WorkerId AS Warning
    FROM   #WorkerTotalHours AS wth
    LEFT JOIN #HourRate      AS hr ON hr.WorkerId = wth.WorkerId
    WHERE  ISNULL(hr.HourRate, 0) = 0

    UNION ALL

    SELECT wth.WorkerId,
           N'No payroll transactions found for worker ' + wth.WorkerId
    FROM   #WorkerTotalHours        AS wth
    LEFT JOIN #TotalCategoryAmount  AS tca ON tca.WorkerId = wth.WorkerId
    WHERE  ISNULL(tca.TotalCategoryAmount, 0) = 0
) AS w
ORDER BY PersonnelNumber, Warning;
