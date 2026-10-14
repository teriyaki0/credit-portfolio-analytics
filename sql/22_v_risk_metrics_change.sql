-- Метрики в длинном формате с изменением к предыдущему срезу (для 01.10 это 01.09).
-- Grain: report_date × metric. Для сумм change — в тенге, для долей — в долях
-- (0.0123 = +1,23 п.п.); change_pct — относительное изменение, только для сумм.

CREATE OR REPLACE VIEW reporting.v_risk_metrics_change AS
WITH long AS (
    SELECT m.report_date, x.sort_order, x.metric, x.label, x.kind, x.value
    FROM reporting.v_risk_metrics m
    CROSS JOIN LATERAL (VALUES
        (1, 'portfolio_kzt',      'Портфель',      'amount', m.portfolio_kzt),
        (2, 'par30_ratio',        'PAR30',         'ratio',  m.par30_ratio),
        (3, 'par90_ratio',        'PAR90',         'ratio',  m.par90_ratio),
        (4, 'npl_ratio',          'NPL',           'ratio',  m.npl_ratio),
        (5, 'provision_kzt',      'Провизии',      'amount', m.provision_kzt),
        (6, 'top10_groups_ratio', 'Топ-10 групп',  'ratio',  m.top10_groups_ratio)
    ) AS x(sort_order, metric, label, kind, value)
),
with_prev AS (
    SELECT
        l.*,
        lag(l.report_date) OVER w AS prev_date,
        lag(l.value)       OVER w AS prev_value
    FROM long l
    WINDOW w AS (PARTITION BY l.metric ORDER BY l.report_date)
)
SELECT
    report_date,
    prev_date,
    sort_order,
    metric,
    label,
    kind,
    value,
    prev_value,
    value - prev_value                                              AS change,
    CASE WHEN kind = 'amount' THEN value / prev_value - 1 END       AS change_pct
FROM with_prev;
