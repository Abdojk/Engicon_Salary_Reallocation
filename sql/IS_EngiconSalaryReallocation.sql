/* =====================================================================
   IS_EngiconSalaryReallocation — report query.

   Plain, read-only T-SQL translation of the X++ data provider class
   IS_EngiconSalaryReallocationDP. Runs against AxDB (SQL Server) and
   returns the salary-reallocation report rows directly — one row per
   (PersonnelNumber, ProjId, TransCode).

   Read-only: WITH (NOLOCK) on every table, no DDL, no DML.
   ===================================================================== */

SET NOCOUNT ON;

-- ---------------------------------------------------------------------
-- Parameters (edit per run)
-- ---------------------------------------------------------------------
DECLARE @DataAreaId             NVARCHAR(4)   = N'ENGJ';
DECLARE @CompanyCode            NVARCHAR(20)  = N'C01';        -- INS_PAYROLLEMPLTRANS.COMPANYCODE; not the same as @DataAreaId
DECLARE @FromDate               DATE          = '2026-02-01';
DECLARE @ToDate                 DATE          = '2026-02-28';
DECLARE @ApprovalStatus         INT           = 6;             -- 6 = Posted on this AxDB's custom TSAppStatus extension
DECLARE @WorkerPersonnelNumber  NVARCHAR(25)  = NULL;          -- optional filter; NULL = all workers
DECLARE @ProjId                 NVARCHAR(20)  = NULL;          -- optional filter; NULL = all projects

WITH
-- Flatten tsWeek.Hours[1..7] into one row per day, filtered to the
-- date window and approval status.
WeekDays AS (
    SELECT
        rv.RESOURCEID                              AS WorkerId,
        tsLine.PROJID                              AS ProjId,
        d.Hours                                    AS Hours
    FROM TSTIMESHEETTABLE     AS ts     WITH (NOLOCK)
    JOIN RESOURCEVIEW         AS rv     WITH (NOLOCK)
        ON  rv.RECID             = ts.RESOURCE_
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
      AND (@WorkerPersonnelNumber IS NULL OR rv.RESOURCEID = @WorkerPersonnelNumber)
),
-- Per-(worker, project) hours.
ProjectHours AS (
    SELECT WorkerId, ProjId, SUM(Hours) AS ProjHours
    FROM   WeekDays
    GROUP BY WorkerId, ProjId
),
-- Per-project total hours across all selected workers.
ProjectTotalHours AS (
    SELECT ProjId, SUM(Hours) AS TotalHours
    FROM   WeekDays
    GROUP BY ProjId
),
-- Per-worker total hours; workers summing to zero are dropped.
WorkerTotalHours AS (
    SELECT WorkerId, SUM(ProjHours) AS WorkerTotalHours
    FROM   ProjectHours
    GROUP BY WorkerId
    HAVING SUM(ProjHours) <> 0
),
-- Per-(worker, TransCode) payroll cost for the YEAR/MONTH of @FromDate.
PayrollByTransCode AS (
    SELECT
        p.PERSONNELNUMBER  AS WorkerId,
        p.TRANSCODE        AS TransCode,
        SUM(p.COSTAMOUNT)  AS CostAmount
    FROM INS_PAYROLLEMPLTRANS AS p WITH (NOLOCK)
    WHERE p.[YEAR]      = YEAR(@FromDate)
      AND p.[MONTH]     = MONTH(@FromDate)
      AND p.PROJECTCOST <> 0
      AND p.COMPANYCODE = @CompanyCode
    GROUP BY p.PERSONNELNUMBER, p.TRANSCODE
),
-- Per-worker total payroll cost.
TotalCategoryAmount AS (
    SELECT WorkerId, SUM(CostAmount) AS TotalCategoryAmount
    FROM   PayrollByTransCode
    GROUP BY WorkerId
),
-- Per-worker hour rate: latest cost price effective on or before @ToDate.
HourRate AS (
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
    FROM RESOURCEVIEW AS rv WITH (NOLOCK)
    WHERE rv.RESOURCECOMPANYID = @DataAreaId
      AND EXISTS (SELECT 1 FROM WorkerTotalHours wth WHERE wth.WorkerId = rv.RESOURCEID)
),
-- TransCode -> human-readable description.
TransName AS (
    SELECT ti.TRANSCODE AS TransCode, MAX(ti.TRANSDESC) AS TransDesc
    FROM   INS_PAYROLLTRANSINFOTABLE AS ti WITH (NOLOCK)
    GROUP BY ti.TRANSCODE
)
-- ---------------------------------------------------------------------
-- Report rows: one per (PersonnelNumber, ProjId, TransCode)
--   ActualAmount   = ABS((CostAmount / workerTotalHours) * projHours)
--   StandardAmount = ABS(projHours * hourRate * (CostAmount / totalCategoryAmount))
-- ---------------------------------------------------------------------
SELECT
    ph.WorkerId                                                   AS PersonnelNumber,
    dp.NAME                                                       AS WorkerName,
    ph.ProjId,
    pt.NAME                                                       AS ProjName,
    pt.PROJGROUPID                                                AS ProjGroupId,
    ph.ProjHours                                                  AS ProjectHours,
    pth.TotalHours                                                AS TotalHours,
    ptc.TransCode,
    COALESCE(tn.TransDesc, ptc.TransCode)                         AS TransCodeName,
    ptc.CostAmount                                                AS TransAmount,
    ABS( (ptc.CostAmount / wth.WorkerTotalHours) * ph.ProjHours ) AS ActualAmount,
    CASE
        WHEN tca.TotalCategoryAmount IS NULL
          OR tca.TotalCategoryAmount = 0 THEN 0
        ELSE ABS(
                ph.ProjHours
              * ISNULL(hr.HourRate, 0)
              * (ptc.CostAmount / tca.TotalCategoryAmount)
             )
    END                                                           AS StandardAmount
FROM      ProjectHours        AS ph
JOIN      WorkerTotalHours    AS wth ON wth.WorkerId = ph.WorkerId
JOIN      PayrollByTransCode  AS ptc ON ptc.WorkerId = ph.WorkerId
JOIN      TotalCategoryAmount AS tca ON tca.WorkerId = ph.WorkerId
JOIN      ProjectTotalHours   AS pth ON pth.ProjId   = ph.ProjId
LEFT JOIN HourRate            AS hr  ON hr.WorkerId  = ph.WorkerId
LEFT JOIN TransName           AS tn  ON tn.TransCode = ptc.TransCode
LEFT JOIN PROJTABLE           AS pt  WITH (NOLOCK)
       ON pt.PROJID     = ph.ProjId
      AND pt.DATAAREAID = @DataAreaId
LEFT JOIN HCMWORKER           AS w   WITH (NOLOCK)
       ON w.PERSONNELNUMBER = ph.WorkerId
LEFT JOIN DIRPARTYTABLE       AS dp  WITH (NOLOCK)
       ON dp.RECID = w.PERSON
WHERE (@ProjId IS NULL OR ph.ProjId = @ProjId)
ORDER BY ph.WorkerId, ph.ProjId, ptc.TransCode;
