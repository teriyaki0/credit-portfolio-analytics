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
        lag(s.days_past_due)  OVER w                                        AS prev_days_past_due,
        lag(s.report_date)    OVER w                                        AS prev_report_date,
        lag(s.is_written_off) OVER w                                        AS prev_is_written_off,
        lag(s.principal_orig) OVER w                                        AS prev_principal_orig
    FROM reporting.v_loan_snapshot s
    WINDOW w AS (PARTITION BY s.loan_id ORDER BY s.report_date)
),
dpd_reset AS (
    -- В прошлом срезе просрочка больше 90 дней, сейчас 0 — без реструктуризации и без списания.
    -- Погасить многомесячную просрочку за один срез возможно, но тогда остаток падает больше
    -- обычного платежа; details показывает, насколько он изменился.
    -- Альтернатива: просрочку не погашали — она выросла на число дней между срезами.
    SELECT
        c.*,
        h.prev_days_past_due,
        c.principal_orig / h.prev_principal_orig - 1                            AS principal_change,
        h.prev_days_past_due + (c.report_date - h.prev_report_date)            AS alt_days_past_due
    FROM reporting.v_portfolio_clean c
    JOIN history h USING (loan_id, report_date)
    WHERE h.prev_days_past_due > 90
      AND c.days_past_due = 0
      AND NOT h.prev_is_written_off
      AND NOT c.is_restructured
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
FROM matured_alt m
UNION ALL
SELECT
    'dpd_reset_from_npl',
    d.report_date,
    d.loan_id,
    format('просрочка %s → 0 дн.; остаток %s%% к прошлому срезу',
           d.prev_days_past_due, round(d.principal_change * 100, 1)),
    d.portfolio_kzt,
    d.par30_kzt,
    d.par90_kzt,
    d.npl_kzt,
    d.provision_kzt,
    d.portfolio_kzt,
    d.portfolio_kzt,
    d.portfolio_kzt,
    d.portfolio_kzt,
    d.portfolio_kzt * reporting.provision_rate(true, d.alt_days_past_due)
FROM dpd_reset d;
