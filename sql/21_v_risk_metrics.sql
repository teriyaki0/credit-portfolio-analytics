-- Риск-метрики портфеля на каждую дату среза.
-- Grain: report_date. Доли = сумма числителя / сумма портфеля, не среднее долей по кредитам.

CREATE OR REPLACE VIEW reporting.v_risk_metrics AS
WITH totals AS (
    SELECT
        report_date,
        count(*)            AS loans,
        sum(portfolio_kzt)  AS portfolio_kzt,
        sum(par30_kzt)      AS par30_kzt,
        sum(par90_kzt)      AS par90_kzt,
        sum(npl_kzt)        AS npl_kzt,
        sum(provision_kzt)  AS provision_kzt
    FROM reporting.v_portfolio_clean
    GROUP BY report_date
),
top10 AS (
    SELECT report_date, sum(exposure_kzt) AS top10_groups_kzt
    FROM reporting.v_group_exposure
    WHERE exposure_rank <= 10
    GROUP BY report_date
)
SELECT
    t.report_date,
    t.loans,
    t.portfolio_kzt,
    t.par30_kzt,
    t.par90_kzt,
    t.npl_kzt,
    t.provision_kzt,
    c.top10_groups_kzt,
    t.par30_kzt        / t.portfolio_kzt AS par30_ratio,
    t.par90_kzt        / t.portfolio_kzt AS par90_ratio,
    t.npl_kzt          / t.portfolio_kzt AS npl_ratio,
    t.provision_kzt    / t.portfolio_kzt AS provision_ratio,
    c.top10_groups_kzt / t.portfolio_kzt AS top10_groups_ratio
FROM totals t
JOIN top10 c USING (report_date);
