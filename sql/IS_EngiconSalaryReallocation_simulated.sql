/* =====================================================================
   IS_EngiconSalaryReallocation — SIMULATION variant
   Same logic as the canonical script, except #HourRate adds a
   forward-looking fallback for workers whose latest TRANSDATE <= @ToDate
   row in PROJHOURCOSTPRICE is missing or zero.

   Simulation rule (per user 2026-05-17):
     - "Only when canonical rate is missing"  →  forward fallback fires
       only when the canonical (backward) rate is NULL or 0.
     - "Unbounded nearest-neighbour"          →  forward picks the
       earliest TRANSDATE > @ToDate, with no month-limit.

   Emits a side-by-side result set: canonical + simulated columns +
   provenance flag + delta. A summary result set follows, totalling
   the simulation's effect.

   Read-only. WITH (NOLOCK). Writes only to local #temp tables.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @DataAreaId             NVARCHAR(4)   = N'ENGJ';
DECLARE @CompanyCode            NVARCHAR(20)  = N'C01';
DECLARE @FromDate               DATE          = '2026-02-01';
DECLARE @ToDate                 DATE          = '2026-02-28';
DECLARE @ApprovalStatus         INT           = 6;
DECLARE @WorkerPersonnelNumber  NVARCHAR(25)  = NULL;
DECLARE @ProjId                 NVARCHAR(20)  = NULL;

IF @FromDate IS NULL OR @ToDate IS NULL
    THROW 50000, 'Please select From date and To date.', 1;
IF @FromDate > @ToDate
    THROW 50001, 'From date cannot be greater than To date.', 1;
IF DATEDIFF(DAY, @FromDate, @ToDate) > 366
    THROW 50002, 'Date range cannot exceed one year.', 1;

-- STEP 0: schema validation (identical to canonical script)
IF OBJECT_ID('tempdb..#Required') IS NOT NULL DROP TABLE #Required;
CREATE TABLE #Required (TableName SYSNAME NOT NULL, ColumnName SYSNAME NOT NULL);

INSERT INTO #Required (TableName, ColumnName) VALUES
 ('TSTIMESHEETTABLE','TIMESHEETNBR'),('TSTIMESHEETTABLE','APPROVALSTATUS'),
 ('TSTIMESHEETTABLE','RESOURCE_'),('TSTIMESHEETTABLE','DATAAREAID'),
 ('TSTIMESHEETLINE','TIMESHEETNBR'),('TSTIMESHEETLINE','RECID'),
 ('TSTIMESHEETLINE','PROJID'),('TSTIMESHEETLINE','DATAAREAID'),
 ('TSTIMESHEETLINEWEEK','TSTIMESHEETLINE'),('TSTIMESHEETLINEWEEK','DAYFROM'),
 ('TSTIMESHEETLINEWEEK','HOURS'),
 ('TSTIMESHEETLINEWEEK','HOURS2_'),('TSTIMESHEETLINEWEEK','HOURS3_'),
 ('TSTIMESHEETLINEWEEK','HOURS4_'),('TSTIMESHEETLINEWEEK','HOURS5_'),
 ('TSTIMESHEETLINEWEEK','HOURS6_'),('TSTIMESHEETLINEWEEK','HOURS7_'),
 ('RESOURCEVIEW','RECID'),('RESOURCEVIEW','RESOURCEID'),
 ('RESOURCEVIEW','RESOURCECOMPANYID'),
 ('HCMWORKER','PERSONNELNUMBER'),('HCMWORKER','RECID'),
 ('HCMWORKER','PERSON'),
 ('DIRPARTYTABLE','RECID'),('DIRPARTYTABLE','NAME'),
 ('PROJTABLE','PROJID'),('PROJTABLE','NAME'),
 ('PROJTABLE','PROJGROUPID'),('PROJTABLE','DATAAREAID'),
 ('INS_PAYROLLEMPLTRANS','PERSONNELNUMBER'),('INS_PAYROLLEMPLTRANS','YEAR'),
 ('INS_PAYROLLEMPLTRANS','MONTH'),('INS_PAYROLLEMPLTRANS','TRANSCODE'),
 ('INS_PAYROLLEMPLTRANS','COSTAMOUNT'),('INS_PAYROLLEMPLTRANS','PROJECTCOST'),
 ('INS_PAYROLLEMPLTRANS','COMPANYCODE'),
 ('INS_PAYROLLTRANSINFOTABLE','TRANSCODE'),('INS_PAYROLLTRANSINFOTABLE','TRANSDESC'),
 ('PROJHOURCOSTPRICE','COSTPRICE'),('PROJHOURCOSTPRICE','TRANSDATE'),
 ('PROJHOURCOSTPRICE','RESOURCE_'),('PROJHOURCOSTPRICE','DATAAREAID');

DECLARE @missing NVARCHAR(MAX) =
    (SELECT STRING_AGG(r.TableName + N'.' + r.ColumnName, N', ')
     FROM #Required AS r
     WHERE NOT EXISTS (
         SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS AS c
         WHERE UPPER(c.TABLE_NAME)=r.TableName AND UPPER(c.COLUMN_NAME)=r.ColumnName));

IF @missing IS NOT NULL AND LEN(@missing) > 0
BEGIN
    DECLARE @msg NVARCHAR(MAX) = N'Schema validation failed. Missing identifiers: ' + @missing;
    THROW 50100, @msg, 1;
END;

-- STEPS 1-6 unchanged from canonical
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

IF OBJECT_ID('tempdb..#ProjectHours') IS NOT NULL DROP TABLE #ProjectHours;
SELECT WorkerId, ProjId, SUM(Hours) AS ProjHours INTO #ProjectHours
FROM #WeekDays GROUP BY WorkerId, ProjId;

IF OBJECT_ID('tempdb..#ProjectTotalHours') IS NOT NULL DROP TABLE #ProjectTotalHours;
SELECT ProjId, SUM(Hours) AS TotalHours INTO #ProjectTotalHours
FROM #WeekDays GROUP BY ProjId;

IF OBJECT_ID('tempdb..#WorkerTotalHours') IS NOT NULL DROP TABLE #WorkerTotalHours;
SELECT WorkerId, SUM(ProjHours) AS WorkerTotalHours INTO #WorkerTotalHours
FROM #ProjectHours GROUP BY WorkerId HAVING SUM(ProjHours) <> 0;

IF OBJECT_ID('tempdb..#PayrollByTransCode') IS NOT NULL DROP TABLE #PayrollByTransCode;
SELECT p.PERSONNELNUMBER AS WorkerId, p.TRANSCODE AS TransCode, SUM(p.COSTAMOUNT) AS CostAmount
INTO #PayrollByTransCode
FROM INS_PAYROLLEMPLTRANS AS p WITH (NOLOCK)
WHERE p.[YEAR] = YEAR(@FromDate) AND p.[MONTH] = MONTH(@FromDate)
  AND p.PROJECTCOST <> 0 AND p.COMPANYCODE = @CompanyCode
GROUP BY p.PERSONNELNUMBER, p.TRANSCODE;

IF OBJECT_ID('tempdb..#TotalCategoryAmount') IS NOT NULL DROP TABLE #TotalCategoryAmount;
SELECT WorkerId, SUM(CostAmount) AS TotalCategoryAmount INTO #TotalCategoryAmount
FROM #PayrollByTransCode GROUP BY WorkerId;

-- STEP 7 (EXTENDED): hour rate with backward + forward candidates
--   HourRate_Backward = latest TRANSDATE <= @ToDate                (canonical behaviour)
--   HourRate_Forward  = earliest TRANSDATE > @ToDate                (simulation)
--   HourRate_Effective = COALESCE(NULLIF(Backward, 0), Forward, 0)
--     i.e. only fall back to Forward when Backward is missing or zero
IF OBJECT_ID('tempdb..#HourRate') IS NOT NULL DROP TABLE #HourRate;
SELECT
    rv.RESOURCEID                                AS WorkerId,
    ROUND(b.COSTPRICE, 3)                        AS HourRate_Backward,
    b.TRANSDATE                                  AS BackwardDate,
    ROUND(f.COSTPRICE, 3)                        AS HourRate_Forward,
    f.TRANSDATE                                  AS ForwardDate
INTO #HourRate
FROM RESOURCEVIEW AS rv WITH (NOLOCK)
OUTER APPLY (
    SELECT TOP (1) phc.COSTPRICE, phc.TRANSDATE
    FROM PROJHOURCOSTPRICE AS phc WITH (NOLOCK)
    WHERE phc.DATAAREAID = @DataAreaId
      AND phc.RESOURCE_  = rv.RECID
      AND phc.TRANSDATE <= @ToDate
    ORDER BY phc.TRANSDATE DESC
) AS b
OUTER APPLY (
    SELECT TOP (1) phc.COSTPRICE, phc.TRANSDATE
    FROM PROJHOURCOSTPRICE AS phc WITH (NOLOCK)
    WHERE phc.DATAAREAID = @DataAreaId
      AND phc.RESOURCE_  = rv.RECID
      AND phc.TRANSDATE > @ToDate
    ORDER BY phc.TRANSDATE ASC
) AS f
WHERE rv.RESOURCECOMPANYID = @DataAreaId
  AND EXISTS (SELECT 1 FROM #WorkerTotalHours wth WHERE wth.WorkerId = rv.RESOURCEID);

IF OBJECT_ID('tempdb..#TransName') IS NOT NULL DROP TABLE #TransName;
SELECT ti.TRANSCODE AS TransCode, MAX(ti.TRANSDESC) AS TransDesc INTO #TransName
FROM INS_PAYROLLTRANSINFOTABLE AS ti WITH (NOLOCK) GROUP BY ti.TRANSCODE;

-- ---------------------------------------------------------------------
-- MAIN RESULT SET: canonical 12 columns + 3 simulation columns
--   HourRateSource:
--     'Original'                 — used Backward rate (canonical behaviour)
--     'Simulated (Forward + N months)' — Backward missing/zero, fell back to Forward
--     'NoneFound'                — neither rate available; both StandardAmounts 0
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
        WHEN ISNULL(hr.HourRate_Backward, 0) <> 0 THEN N'Original'
        WHEN hr.HourRate_Forward IS NOT NULL THEN
            N'Simulated (Forward +'
            + CAST(DATEDIFF(MONTH, @ToDate, hr.ForwardDate) AS NVARCHAR(10))
            + N' months)'
        ELSE N'NoneFound'
    END                                                                    AS HourRateSource,

    -- Canonical: only the backward rate counts
    CASE
        WHEN tca.TotalCategoryAmount IS NULL
          OR tca.TotalCategoryAmount = 0 THEN 0
        ELSE ABS(
                ph.ProjHours
              * ISNULL(hr.HourRate_Backward, 0)
              * (ptc.CostAmount / tca.TotalCategoryAmount)
             )
    END                                                                    AS StandardAmount_Original,

    -- Simulated: forward fallback when backward is missing or zero
    CASE
        WHEN tca.TotalCategoryAmount IS NULL
          OR tca.TotalCategoryAmount = 0 THEN 0
        ELSE ABS(
                ph.ProjHours
              * COALESCE(NULLIF(hr.HourRate_Backward, 0), hr.HourRate_Forward, 0)
              * (ptc.CostAmount / tca.TotalCategoryAmount)
             )
    END                                                                    AS StandardAmount_Simulated,

    -- Delta = Simulated - Original  (positive when simulation adds value)
    CASE
        WHEN tca.TotalCategoryAmount IS NULL
          OR tca.TotalCategoryAmount = 0 THEN 0
        ELSE
            ABS(
                ph.ProjHours
              * COALESCE(NULLIF(hr.HourRate_Backward, 0), hr.HourRate_Forward, 0)
              * (ptc.CostAmount / tca.TotalCategoryAmount)
            )
          - ABS(
                ph.ProjHours
              * ISNULL(hr.HourRate_Backward, 0)
              * (ptc.CostAmount / tca.TotalCategoryAmount)
            )
    END                                                                    AS StandardAmount_Delta
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
-- SUMMARY RESULT SET: how much the simulation moves
-- ---------------------------------------------------------------------
;WITH base AS (
    SELECT
        ph.WorkerId,
        ph.ProjId,
        ptc.TransCode,
        ph.ProjHours,
        ptc.CostAmount,
        tca.TotalCategoryAmount,
        hr.HourRate_Backward,
        hr.HourRate_Forward
    FROM      #ProjectHours        AS ph
    JOIN      #WorkerTotalHours    AS wth ON wth.WorkerId = ph.WorkerId
    JOIN      #PayrollByTransCode  AS ptc ON ptc.WorkerId = ph.WorkerId
    JOIN      #TotalCategoryAmount AS tca ON tca.WorkerId = ph.WorkerId
    LEFT JOIN #HourRate            AS hr  ON hr.WorkerId  = ph.WorkerId
    WHERE (@ProjId IS NULL OR ph.ProjId = @ProjId)
),
calc AS (
    SELECT
        WorkerId,
        CASE WHEN ISNULL(HourRate_Backward, 0) <> 0 THEN 'Original'
             WHEN HourRate_Forward IS NOT NULL THEN 'Simulated'
             ELSE 'NoneFound' END                                              AS Source,
        CASE WHEN TotalCategoryAmount IS NULL OR TotalCategoryAmount = 0 THEN 0
             ELSE ABS(ProjHours * ISNULL(HourRate_Backward, 0)
                      * (CostAmount / TotalCategoryAmount)) END                AS StdOriginal,
        CASE WHEN TotalCategoryAmount IS NULL OR TotalCategoryAmount = 0 THEN 0
             ELSE ABS(ProjHours * COALESCE(NULLIF(HourRate_Backward, 0), HourRate_Forward, 0)
                      * (CostAmount / TotalCategoryAmount)) END                AS StdSimulated
    FROM base
)
SELECT
    Source,
    COUNT(*)                                                                   AS Rows,
    COUNT(DISTINCT WorkerId)                                                   AS DistinctWorkers,
    SUM(StdOriginal)                                                           AS SumOriginal,
    SUM(StdSimulated)                                                          AS SumSimulated,
    SUM(StdSimulated - StdOriginal)                                            AS SumDelta,
    SUM(ABS(StdSimulated - StdOriginal))                                       AS SumAbsDelta
FROM calc
GROUP BY Source
ORDER BY Source;
