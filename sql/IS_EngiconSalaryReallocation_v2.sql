/* =====================================================================
   IS_EngiconSalaryReallocation_v2 — pure-CTE T-SQL replication of the
   X++ report Data Provider class IS_EngiconSalaryReallocationDP.
   ---------------------------------------------------------------------
   Read-only. A single DECLARE block followed by one WITH ... SELECT.
   No DDL, no DML, no temp tables, no batch splits. Safe to run against
   a production AxDB.

   Scope : legal entity ENGJ, payroll CompanyCode C01, February 2026.

   Targets (audited Reallocation Report By Project):
     SUM(ActualAmount)   = 634,112.27 JOD
     SUM(StandardAmount) = 649,305.48 JOD

   ---------------------------------------------------------------------
   SCHEMA CONFIRMED via diagnostics run 2026-05-21
   (sql/IS_EngiconSalaryReallocation_diagnostics.sql):
     - TSTimesheetTable resource column .............. RESOURCE_ (bigint)
     - TSTimesheetLineWeek day columns ............... HOURS, HOURS2_..HOURS7_
     - TSTimesheetLineWeek.DAYFROM ................... datetime
     - ProjHourCostPrice ............................. TRANSDATE, RESOURCE_,
                                                       CATEGORYID (nvarchar),
                                                       COSTPRICE, DATAAREAID
     - ResourceView .................................. VIEW; RECID,
                                                       RESOURCEID, RESOURCECOMPANYID
     - INS_PayrollEmplTrans .......................... no DATAAREAID column;
                                                       COMPANYCODE, YEAR, MONTH,
                                                       PERSONNELNUMBER, TRANSCODE,
                                                       COSTAMOUNT, PROJECTCOST
     - HcmWorker ..................................... global (no DATAAREAID);
                                                       PERSONNELNUMBER, RECID, PERSON
     - ApprovalStatus = 6 ............................ dominant value for
                                                       Feb 2026 (1,246 timesheets)

   FIDELITY CORRECTIONS over the prior script
   (sql/IS_EngiconSalaryReallocation.sql):
     1. Stage 1 joins ResourceView on RECID ONLY. The prior script added
        rv.ResourceCompanyId = @DataAreaId, which the X++ Stage 1 join
        does not have; that filter dropped timesheet hours for workers
        whose resource sits under another company, excluding their
        payroll cost from reallocation.
     2. Stage 3 hour-rate lookup filters ProjHourCostPrice.CategoryId,
        replicating ResourceFacade::getCostPrice(rv.RecId, toDate, 0).
        The prior script omitted this filter.

   ASSUMPTIONS (labelled):
     A. Output column "TotalHours" carries the PROJECT total hours across
        all workers (X++ tmpTable.TotalHours = projectTotalHours.lookup),
        matching the SSRS dataset field. The task's column-list label
        "WorkerTotalHours" is treated as a naming slip.
     B. getCostPrice's 3rd argument 0 maps to ProjHourCostPrice.CategoryId.
        CATEGORYID is nvarchar, so the value is supplied as the parameter
        @HourRateCategoryId (default N'0'). Confirm the correct literal
        via diagnostics Section 11/12 before relying on StandardAmount.
     C. HcmWorker.name() resolves via HcmWorker.Person -> DirPartyTable.
   ===================================================================== */

-- ---------------------------------------------------------------------
-- Parameters
-- ---------------------------------------------------------------------
DECLARE @DataAreaId            NVARCHAR(4)   = N'ENGJ';        -- AX legal entity (timesheet/project/resource tables)
DECLARE @CompanyCode           NVARCHAR(20)  = N'C01';         -- INS_PayrollEmplTrans.CompanyCode (not DataAreaId)
DECLARE @FromDate              DATE          = '2026-02-01';
DECLARE @ToDate                DATE          = '2026-02-28';
DECLARE @ApprovalStatus        INT           = 6;              -- confirmed: dominant Feb-2026 value
DECLARE @HourRateCategoryId    NVARCHAR(20)  = N'0';           -- ProjHourCostPrice.CategoryId for the rate lookup (assumption B)
DECLARE @WorkerPersonnelNumber NVARCHAR(25)  = NULL;           -- optional; NULL = all workers
DECLARE @ProjId                NVARCHAR(20)  = NULL;           -- optional; NULL = all projects

WITH
-- Stage 1a: clip each week record's 7 day-hour columns to [@FromDate,@ToDate].
-- Join ResourceView on RECID only (no company filter) — see fidelity fix 1.
WeekClippedHours AS (
    SELECT
        rv.RESOURCEID AS WorkerId,
        tsl.PROJID    AS ProjId,
          ISNULL(CASE WHEN DATEADD(day,0,tslw.DAYFROM) BETWEEN @FromDate AND @ToDate THEN tslw.HOURS   END, 0)
        + ISNULL(CASE WHEN DATEADD(day,1,tslw.DAYFROM) BETWEEN @FromDate AND @ToDate THEN tslw.HOURS2_ END, 0)
        + ISNULL(CASE WHEN DATEADD(day,2,tslw.DAYFROM) BETWEEN @FromDate AND @ToDate THEN tslw.HOURS3_ END, 0)
        + ISNULL(CASE WHEN DATEADD(day,3,tslw.DAYFROM) BETWEEN @FromDate AND @ToDate THEN tslw.HOURS4_ END, 0)
        + ISNULL(CASE WHEN DATEADD(day,4,tslw.DAYFROM) BETWEEN @FromDate AND @ToDate THEN tslw.HOURS5_ END, 0)
        + ISNULL(CASE WHEN DATEADD(day,5,tslw.DAYFROM) BETWEEN @FromDate AND @ToDate THEN tslw.HOURS6_ END, 0)
        + ISNULL(CASE WHEN DATEADD(day,6,tslw.DAYFROM) BETWEEN @FromDate AND @ToDate THEN tslw.HOURS7_ END, 0)
            AS ClippedHours
    FROM TSTimesheetTable     AS tst  WITH (NOLOCK)
    JOIN ResourceView         AS rv   WITH (NOLOCK)
        ON rv.RECID = tst.RESOURCE_
    JOIN TSTimesheetLine      AS tsl  WITH (NOLOCK)
        ON  tsl.TIMESHEETNBR = tst.TIMESHEETNBR
        AND tsl.DATAAREAID   = tst.DATAAREAID
    JOIN TSTimesheetLineWeek  AS tslw WITH (NOLOCK)
        ON tslw.TSTIMESHEETLINE = tsl.RECID
    WHERE tst.APPROVALSTATUS = @ApprovalStatus
      AND tst.DATAAREAID     = @DataAreaId
      AND tslw.DAYFROM <= @ToDate
      AND DATEADD(day, 6, tslw.DAYFROM) >= @FromDate
      AND (@WorkerPersonnelNumber IS NULL OR rv.RESOURCEID = @WorkerPersonnelNumber)
),

-- Stage 1b: hours per (worker, project)  — X++ projectMap
WorkerProjectHours AS (
    SELECT WorkerId, ProjId, SUM(ClippedHours) AS ProjHours
    FROM WeekClippedHours
    GROUP BY WorkerId, ProjId
),

-- Stage 1c: hours per project across ALL workers  — X++ projectTotalHours
ProjectTotalHours AS (
    SELECT ProjId, SUM(ProjHours) AS ProjectTotalHours
    FROM WorkerProjectHours
    GROUP BY ProjId
),

-- Stage 1d: hours per worker  — X++ workerTotalHours; HAVING <> 0 is the
-- X++ `continue` that skips workers with zero approved hours.
WorkerTotalHours AS (
    SELECT WorkerId, SUM(ProjHours) AS WorkerTotalHours
    FROM WorkerProjectHours
    GROUP BY WorkerId
    HAVING SUM(ProjHours) <> 0
),

-- Stage 2a: payroll cost per (worker, TransCode)  — X++ categoryAmountMap.
-- INS_PayrollEmplTrans has no DataAreaId; filter on CompanyCode instead.
PayrollByTransCode AS (
    SELECT
        p.PERSONNELNUMBER AS WorkerId,
        p.TRANSCODE       AS TransCode,
        SUM(p.COSTAMOUNT) AS CostAmount
    FROM INS_PayrollEmplTrans AS p WITH (NOLOCK)
    WHERE p.COMPANYCODE = @CompanyCode
      AND p.[YEAR]      = YEAR(@FromDate)
      AND p.[MONTH]     = MONTH(@FromDate)
      AND p.PROJECTCOST <> 0
      AND p.TRANSCODE IS NOT NULL
      AND LTRIM(RTRIM(p.TRANSCODE)) <> ''      -- excludes any embedded SUBTOTAL row
    GROUP BY p.PERSONNELNUMBER, p.TRANSCODE
),

-- Stage 2b: total payroll cost per worker  — X++ totalCategoryAmount
TotalCategoryAmount AS (
    SELECT WorkerId, SUM(CostAmount) AS TotalCategoryAmount
    FROM PayrollByTransCode
    GROUP BY WorkerId
),

-- Stage 3: most recent hour cost price as of @ToDate  —
-- X++ ResourceFacade::getCostPrice(rv.RecId, toDate, 0), rounded to 0.001.
HourRate AS (
    SELECT
        rv.RESOURCEID AS WorkerId,
        ROUND((
            SELECT TOP (1) phc.COSTPRICE
            FROM ProjHourCostPrice AS phc WITH (NOLOCK)
            WHERE phc.RESOURCE_  = rv.RECID
              AND phc.DATAAREAID = @DataAreaId
              AND phc.CATEGORYID = @HourRateCategoryId
              AND phc.TRANSDATE <= @ToDate
            ORDER BY phc.TRANSDATE DESC
        ), 3) AS HourRate
    FROM ResourceView AS rv WITH (NOLOCK)
    WHERE rv.RESOURCECOMPANYID = @DataAreaId
),

-- TransCode -> description  — X++ transNameMap. Deduplicated so the
-- LEFT JOIN below cannot fan out rows.
TransName AS (
    SELECT TRANSCODE AS TransCode, MAX(TRANSDESC) AS TransDesc
    FROM INS_PayrollTransInfoTable WITH (NOLOCK)
    GROUP BY TRANSCODE
)

-- Stage 4: one row per (worker, project, TransCode).
--   ActualAmount   = ABS( (CostAmount / WorkerTotalHours) * ProjHours )
--   StandardAmount = ABS( ProjHours * HourRate * (CostAmount / TotalCategoryAmount) )
SELECT
    wph.WorkerId                                                  AS PersonnelNumber,
    dp.NAME                                                       AS WorkerName,
    wph.ProjId                                                    AS ProjId,
    pt.NAME                                                       AS ProjName,
    pt.PROJGROUPID                                                AS ProjGroupId,
    wph.ProjHours                                                 AS ProjectHours,
    pth.ProjectTotalHours                                         AS TotalHours,
    ptc.TransCode                                                 AS TransCode,
    COALESCE(tn.TransDesc, ptc.TransCode)                         AS TransCodeName,
    ptc.CostAmount                                                AS TransAmount,
    ABS( (CAST(ptc.CostAmount AS FLOAT) / wth.WorkerTotalHours)
         * wph.ProjHours )                                        AS ActualAmount,
    ABS( CAST(wph.ProjHours AS FLOAT)
         * ISNULL(hr.HourRate, 0)
         * (ptc.CostAmount / tca.TotalCategoryAmount) )           AS StandardAmount
FROM      WorkerProjectHours  AS wph
JOIN      WorkerTotalHours    AS wth ON wth.WorkerId = wph.WorkerId
JOIN      PayrollByTransCode  AS ptc ON ptc.WorkerId = wph.WorkerId
JOIN      TotalCategoryAmount AS tca ON tca.WorkerId = wph.WorkerId
                                    AND tca.TotalCategoryAmount <> 0
JOIN      ProjectTotalHours   AS pth ON pth.ProjId   = wph.ProjId
LEFT JOIN HourRate            AS hr  ON hr.WorkerId  = wph.WorkerId
LEFT JOIN TransName           AS tn  ON tn.TransCode = ptc.TransCode
LEFT JOIN ProjTable           AS pt  WITH (NOLOCK)
       ON pt.PROJID     = wph.ProjId
      AND pt.DATAAREAID = @DataAreaId
LEFT JOIN HcmWorker           AS w   WITH (NOLOCK)
       ON w.PERSONNELNUMBER = wph.WorkerId
LEFT JOIN DirPartyTable       AS dp  WITH (NOLOCK)
       ON dp.RECID = w.PERSON
WHERE (@ProjId IS NULL OR wph.ProjId = @ProjId)
ORDER BY wph.WorkerId, wph.ProjId, ptc.TransCode;
/* ===================================================================== */
