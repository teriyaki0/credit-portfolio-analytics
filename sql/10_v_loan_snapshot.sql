-- Срез кредита на дату отчёта: дубли убраны, сумма в тенге, проставлены риск-признаки.
-- Grain: одна строка = loan_id × report_date.
-- Списанные кредиты здесь ещё есть (is_written_off): так по этой вьюхе видно, куда
-- делась каждая строка raw. Исключаются они уровнем выше, в v_portfolio_clean.

CREATE OR REPLACE VIEW reporting.v_loan_snapshot AS
WITH dedup AS (
    -- В raw есть полные дубли строк (совпадают все поля) — схлопываем.
    -- Две строки одного кредита на одну дату с разными значениями DISTINCT не схлопнет:
    -- такой случай должен всплыть в проверках, а не решаться выбором «какой-нибудь» строки.
    SELECT DISTINCT * FROM raw.portfolio
),
base AS (
    SELECT
        d.report_date,
        d.loan_id,
        d.borrower_id,
        d.group_id,
        d.sector,
        d.program,
        upper(trim(d.currency))     AS currency,
        d.issue_date,
        d.maturity_date,
        d.principal_outstanding     AS principal_orig,
        d.days_past_due,
        d.restructured = 1          AS is_restructured,
        d.written_off = 1           AS is_written_off
    FROM dedup d
),
with_fx AS (
    SELECT
        b.*,
        -- Курс строго на дату среза. Нет курса — fx_rate остаётся NULL, и это ошибка;
        -- соседний или последний доступный день не подставляем.
        CASE WHEN b.currency = 'KZT' THEN 1 ELSE fx.rate_kzt END AS fx_rate
    FROM base b
    LEFT JOIN raw.fx fx
           ON fx.date = b.report_date
          AND upper(trim(fx.currency)) = b.currency
)
SELECT
    w.*,
    w.principal_orig * w.fx_rate        AS principal_kzt,
    CASE
        WHEN w.days_past_due = 0   THEN '0'
        WHEN w.days_past_due <= 30 THEN '1–30'
        WHEN w.days_past_due <= 90 THEN '31–90'
        ELSE '>90'
    END                                 AS dpd_bucket,
    w.days_past_due > 30                AS is_par30,
    w.days_past_due > 90                AS is_par90,
    w.days_past_due > 90 OR w.is_restructured AS is_npl
FROM with_fx w;
