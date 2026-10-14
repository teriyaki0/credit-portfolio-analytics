-- Экспозиция на группу связанных заёмщиков (group_id) и её место в рейтинге на дату.
-- Grain: group_id × report_date. Концентрацию считаем по группам, а не по borrower_id:
-- у одной группы может быть несколько заёмщиков, и падают они вместе.

CREATE OR REPLACE VIEW reporting.v_group_exposure AS
WITH g AS (
    SELECT
        report_date,
        group_id,
        count(DISTINCT borrower_id) AS borrowers,
        count(*)                    AS loans,
        sum(portfolio_kzt)          AS exposure_kzt,
        sum(npl_kzt)                AS npl_kzt
    FROM reporting.v_portfolio_clean
    GROUP BY report_date, group_id
)
SELECT
    g.*,
    g.exposure_kzt / sum(g.exposure_kzt) OVER (PARTITION BY g.report_date) AS share,
    -- group_id вторым ключом: при равных суммах рейтинг детерминирован.
    row_number() OVER (PARTITION BY g.report_date ORDER BY g.exposure_kzt DESC, g.group_id) AS exposure_rank
FROM g;
