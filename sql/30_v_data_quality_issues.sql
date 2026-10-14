-- Реестр исключений: конкретные кредиты, данные по которым выглядят подозрительно.
-- Grain: rule × loan_id × report_date.
--
-- Витрину эти правила НЕ меняют: кредит считается по определению, как пришёл из источника.
-- Здесь записано, что не так, и как выглядел бы кредит при альтернативной трактовке (alt_*).
-- По разнице alt_* и фактических сумм v_data_quality_summary считает влияние на метрики.
-- Технические исправления (полные дубли строк) сюда не входят — они видны в сверке v_checks.

CREATE OR REPLACE VIEW reporting.v_data_quality_issues AS
WITH history AS (
    SELECT
        s.loan_id,
        s.report_date,
        -- Последняя дата прошлых срезов, на которую кредит был списан.
        max(s.report_date) FILTER (WHERE s.is_written_off) OVER (
            PARTITION BY s.loan_id ORDER BY s.report_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        )                                                                     AS written_off_on,
        lag(s.days_past_due) OVER (PARTITION BY s.loan_id ORDER BY s.report_date) AS prev_days_past_due
    FROM reporting.v_loan_snapshot s
),
written_off_reversed AS (
    -- Кредит был списан в одном из прошлых срезов, а на эту дату снова в портфеле.
    -- Списание обратно не откатывают: либо его отменили, либо флаг в прошлом срезе ошибочный.
    -- Альтернатива: списание верное, кредита в портфеле нет.
    SELECT
        'written_off_reversed'                  AS rule,
        c.report_date,
        c.loan_id,
        format('списан на %s; просрочка %s → %s дн.',
               to_char(h.written_off_on, 'DD.MM.YYYY'), h.prev_days_past_due, c.days_past_due) AS details,
        c.portfolio_kzt,
        c.par30_kzt,
        c.par90_kzt,
        c.npl_kzt,
        c.provision_kzt,
        0::numeric                              AS alt_portfolio_kzt,
        0::numeric                              AS alt_par30_kzt,
        0::numeric                              AS alt_par90_kzt,
        0::numeric                              AS alt_npl_kzt,
        0::numeric                              AS alt_provision_kzt
    FROM reporting.v_portfolio_clean c
    JOIN history h USING (loan_id, report_date)
    WHERE h.written_off_on IS NOT NULL
),
matured AS (
    -- Срок погашения прошёл, остаток есть, а просрочка меньше числа дней после погашения.
    -- Непогашенный в срок долг — просрочка с даты погашения, если не было пролонгации.
    -- Альтернатива: просрочка не меньше числа дней после погашения.
    SELECT
        c.*,
        c.report_date - c.maturity_date                                     AS days_since_maturity,
        greatest(c.days_past_due, c.report_date - c.maturity_date)          AS alt_days_past_due
    FROM reporting.v_portfolio_clean c
    WHERE c.maturity_date < c.report_date
      AND c.days_past_due < c.report_date - c.maturity_date
),
matured_alt AS (
    SELECT m.*, m.alt_days_past_due > 90 OR m.is_restructured AS alt_is_npl
    FROM matured m
)
SELECT * FROM written_off_reversed
UNION ALL
SELECT
    'matured_dpd_inconsistent',
    m.report_date,
    m.loan_id,
    format('погашение %s (%s дн. назад), просрочка %s дн.',
           to_char(m.maturity_date, 'DD.MM.YYYY'), m.days_since_maturity, m.days_past_due),
    m.portfolio_kzt,
    m.par30_kzt,
    m.par90_kzt,
    m.npl_kzt,
    m.provision_kzt,
    m.portfolio_kzt,
    CASE WHEN m.alt_days_past_due > 30 THEN m.portfolio_kzt ELSE 0 END,
    CASE WHEN m.alt_days_past_due > 90 THEN m.portfolio_kzt ELSE 0 END,
    CASE WHEN m.alt_is_npl             THEN m.portfolio_kzt ELSE 0 END,
    m.portfolio_kzt * reporting.provision_rate(m.alt_is_npl, m.alt_days_past_due)
FROM matured_alt m;
