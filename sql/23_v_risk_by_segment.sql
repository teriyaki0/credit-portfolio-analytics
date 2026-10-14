-- Риск-метрики в разрезе отрасли, программы и корзины просрочки.
-- Grain: report_date × segment_type × segment. Все разрезы в одной вьюхе через GROUPING SETS,
-- чтобы дашборд и проверки брали их из одного места.

CREATE OR REPLACE VIEW reporting.v_risk_by_segment AS
WITH s AS (
    SELECT
        report_date,
        -- Разрез определяем через GROUPING(), а не coalesce(sector, program):
        -- иначе кредит с пустой отраслью попал бы в «отрасль» с названием программы.
        CASE
            WHEN GROUPING(sector)  = 0 THEN 'sector'
            WHEN GROUPING(program) = 0 THEN 'program'
            ELSE 'dpd_bucket'
        END                         AS segment_type,
        CASE
            WHEN GROUPING(sector)  = 0 THEN sector
            WHEN GROUPING(program) = 0 THEN program
            ELSE dpd_bucket
        END                         AS segment,
        count(*)                    AS loans,
        sum(portfolio_kzt)          AS portfolio_kzt,
        sum(par30_kzt)              AS par30_kzt,
        sum(par90_kzt)              AS par90_kzt,
        sum(npl_kzt)                AS npl_kzt,
        sum(provision_kzt)          AS provision_kzt
    FROM reporting.v_portfolio_clean
    GROUP BY GROUPING SETS ((report_date, sector), (report_date, program), (report_date, dpd_bucket))
)
SELECT
    s.*,
    s.portfolio_kzt / sum(s.portfolio_kzt) OVER (PARTITION BY s.report_date, s.segment_type) AS portfolio_share,
    s.par30_kzt     / s.portfolio_kzt AS par30_ratio,
    s.par90_kzt     / s.portfolio_kzt AS par90_ratio,
    s.npl_kzt       / s.portfolio_kzt AS npl_ratio,
    s.provision_kzt / s.portfolio_kzt AS provision_ratio
FROM s;
