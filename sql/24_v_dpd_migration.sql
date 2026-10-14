-- Миграция кредитов между корзинами просрочки от предыдущего среза к текущему (матрица roll-rate).
-- Grain: report_date × from_state × to_state. Состояния: корзины просрочки ('0', '1–30', '31–90',
-- '>90') и 'списан'. Доля перехода — от суммы корзины-источника на прошлую дату (from_share).
-- Кредиты, которых нет в одном из двух срезов (новые или закрытые), в матрицу не входят;
-- полноту проверяет v_checks (migration_complete).

CREATE OR REPLACE VIEW reporting.v_dpd_migration AS
WITH states AS (
    SELECT
        loan_id,
        report_date,
        principal_kzt,
        CASE WHEN is_written_off THEN 'списан' ELSE dpd_bucket END AS state
    FROM reporting.v_loan_snapshot
),
transitions AS (
    SELECT
        s.*,
        lag(s.report_date)   OVER w AS prev_date,
        lag(s.state)         OVER w AS prev_state,
        lag(s.principal_kzt) OVER w AS prev_principal_kzt
    FROM states s
    WINDOW w AS (PARTITION BY s.loan_id ORDER BY s.report_date)
),
matrix AS (
    SELECT
        report_date,
        prev_date,
        prev_state              AS from_state,
        state                   AS to_state,
        count(*)                AS loans,
        sum(prev_principal_kzt) AS from_amount_kzt,
        sum(principal_kzt)      AS to_amount_kzt
    FROM transitions
    WHERE prev_date IS NOT NULL
    GROUP BY 1, 2, 3, 4
)
SELECT
    m.*,
    array_position(ARRAY['0', '1–30', '31–90', '>90', 'списан'], m.from_state) AS from_order,
    array_position(ARRAY['0', '1–30', '31–90', '>90', 'списан'], m.to_state)   AS to_order,
    m.from_amount_kzt / sum(m.from_amount_kzt) OVER (PARTITION BY m.report_date, m.from_state) AS from_share
FROM matrix m;
