-- Проверки витрины: PASS / WARN / FAIL. scripts/load.sh печатает их и завершается
-- с ошибкой, если есть хоть один FAIL.
--   FAIL — посчитать верно нельзя или цифры не сходятся с источником;
--   WARN — данные подозрительные, но метрики посчитаны по определению
--          (кредиты — в v_data_quality_issues, влияние — в v_data_quality_summary).
-- Сверки с raw считаются заново от raw.portfolio / raw.fx, а не через вьюхи витрины.

CREATE OR REPLACE VIEW reporting.v_checks AS
WITH raw_dedup AS (
    SELECT DISTINCT * FROM raw.portfolio
),
m AS (
    SELECT * FROM reporting.v_risk_metrics
),
checks (check_order, check_name, report_date, on_fail, passed, details) AS (

    -- 1. Исходные данные ---------------------------------------------------------------

    SELECT 11, 'raw_required_fields', NULL::date, 'FAIL', n = 0,
           format('строк с пустыми обязательными полями: %s', n)
    FROM (
        SELECT count(*) FILTER (WHERE num_nulls(report_date, loan_id, borrower_id, group_id, sector,
                                                program, currency, issue_date, maturity_date,
                                                principal_outstanding, days_past_due,
                                                restructured, written_off) > 0) AS n
        FROM raw.portfolio
    ) x

    UNION ALL
    SELECT 12, 'raw_value_domains', NULL, 'FAIL', n = 0,
           format('строк с флагом не 0/1, отрицательной просрочкой или суммой: %s', n)
    FROM (
        SELECT count(*) FILTER (WHERE restructured NOT IN (0, 1) OR written_off NOT IN (0, 1)
                                   OR days_past_due < 0 OR principal_outstanding < 0) AS n
        FROM raw.portfolio
    ) x

    UNION ALL
    SELECT 13, 'fx_unique_per_day', NULL, 'FAIL', n = 0,
           format('повторов «дата × валюта» в fx: %s', n)
    FROM (
        SELECT count(*) - count(DISTINCT (date, upper(trim(currency)))) AS n FROM raw.fx
    ) x

    UNION ALL
    SELECT 14, 'loan_unique_per_date', report_date, 'FAIL', n = 0,
           format('кредитов с несколькими строками на дату: %s', n)
    FROM (
        SELECT report_date, count(*) - count(DISTINCT loan_id) AS n
        FROM reporting.v_loan_snapshot
        GROUP BY report_date
    ) x

    -- 2. Курс ---------------------------------------------------------------------------

    UNION ALL
    SELECT 21, 'fx_rate_on_report_date', report_date, 'FAIL', n = 0,
           format('кредитов без курса на дату среза: %s; применён курс: %s', n, coalesce(rates, 'нет'))
    FROM (
        SELECT report_date,
               count(*) FILTER (WHERE fx_rate IS NULL) AS n,
               string_agg(DISTINCT currency || ' ' || fx_rate, ', ') FILTER (WHERE currency <> 'KZT') AS rates
        FROM reporting.v_loan_snapshot
        GROUP BY report_date
    ) x

    -- 3. Сверка с raw -------------------------------------------------------------------

    UNION ALL
    SELECT 31, 'reconcile_rows', r.report_date, 'FAIL',
           r.dedup_rows = r.written_off + c.clean_rows,
           format('%s строк raw = %s в портфеле + %s списано + %s полных дублей',
                  r.raw_rows, c.clean_rows, r.written_off, r.raw_rows - r.dedup_rows)
    FROM (
        SELECT p.report_date,
               count(*)                                                        AS raw_rows,
               (SELECT count(*) FROM raw_dedup d WHERE d.report_date = p.report_date) AS dedup_rows,
               (SELECT count(*) FROM raw_dedup d
                 WHERE d.report_date = p.report_date AND d.written_off = 1)      AS written_off
        FROM raw.portfolio p
        GROUP BY p.report_date
    ) r
    JOIN (
        SELECT report_date, count(*) AS clean_rows FROM reporting.v_portfolio_clean GROUP BY report_date
    ) c USING (report_date)

    UNION ALL
    SELECT 32, 'reconcile_amount_by_currency', r.report_date, 'FAIL',
           r.amount = coalesce(c.amount, 0),
           format('%s: raw без списанных %s = витрина %s (в валюте кредита)',
                  r.currency, r.amount, coalesce(c.amount, 0))
    FROM (
        SELECT report_date, upper(trim(currency)) AS currency, sum(principal_outstanding) AS amount
        FROM raw_dedup WHERE written_off = 0
        GROUP BY 1, 2
    ) r
    LEFT JOIN (
        SELECT report_date, currency, sum(principal_orig) AS amount
        FROM reporting.v_portfolio_clean
        GROUP BY 1, 2
    ) c USING (report_date, currency)

    UNION ALL
    SELECT 33, 'reconcile_portfolio_kzt', m.report_date, 'FAIL',
           coalesce(r.amount_kzt = m.portfolio_kzt, false),
           format('raw × курс на дату = %s ₸, витрина = %s ₸', r.amount_kzt, m.portfolio_kzt)
    FROM m
    LEFT JOIN (
        SELECT d.report_date,
               sum(d.principal_outstanding *
                   CASE WHEN upper(trim(d.currency)) = 'KZT' THEN 1 ELSE f.rate_kzt END) AS amount_kzt
        FROM raw_dedup d
        LEFT JOIN raw.fx f
               ON f.date = d.report_date AND upper(trim(f.currency)) = upper(trim(d.currency))
        WHERE d.written_off = 0
        GROUP BY d.report_date
    ) r USING (report_date)

    -- 4. Определения --------------------------------------------------------------------

    UNION ALL
    SELECT 41, 'risk_ordering', report_date, 'FAIL',
           par90_kzt <= par30_kzt AND par30_kzt <= portfolio_kzt
           AND par90_kzt <= npl_kzt AND npl_kzt <= portfolio_kzt,
           format('PAR90 %s%% ≤ PAR30 %s%%; PAR90 ≤ NPL %s%%',
                  round(par90_ratio * 100, 2), round(par30_ratio * 100, 2), round(npl_ratio * 100, 2))
    FROM m

    UNION ALL
    SELECT 42, 'restructured_is_npl_50pct', report_date, 'FAIL', bad = 0,
           format('реструктуризированных: %s, из них с просрочкой ≤ 90 дн.: %s; не в NPL или ставка не 50%%: %s',
                  total, low_dpd, bad)
    FROM (
        SELECT report_date,
               count(*)                                                     AS total,
               count(*) FILTER (WHERE days_past_due <= 90)                  AS low_dpd,
               count(*) FILTER (WHERE NOT is_npl OR provision_rate <> 0.50) AS bad
        FROM reporting.v_portfolio_clean
        WHERE is_restructured
        GROUP BY report_date
    ) x

    UNION ALL
    SELECT 43, 'dpd_boundaries', report_date, 'FAIL', bad = 0,
           format('просрочка ровно 30 дн.: %s, ровно 90 дн.: %s (по определению не в PAR30 / PAR90); нарушений границ и шкалы: %s',
                  d30, d90, bad)
    FROM (
        SELECT report_date,
               count(*) FILTER (WHERE days_past_due = 30) AS d30,
               count(*) FILTER (WHERE days_past_due = 90) AS d90,
               count(*) FILTER (WHERE
                      (days_past_due = 30 AND is_par30)
                   OR (days_past_due = 90 AND is_par90)
                   OR (NOT is_restructured AND days_past_due BETWEEN 31 AND 90 AND provision_rate <> 0.10)
                   OR (NOT is_restructured AND days_past_due <= 30 AND provision_rate <> 0.01)
               ) AS bad
        FROM reporting.v_portfolio_clean
        GROUP BY report_date
    ) x

    UNION ALL
    SELECT 44, 'provision_bounds', report_date, 'FAIL',
           provision_ratio BETWEEN 0.01 AND 0.50,
           format('провизии %s%% портфеля (допустимо 1–50%%)', round(provision_ratio * 100, 2))
    FROM m

    -- 5. Согласованность агрегатов -------------------------------------------------------

    UNION ALL
    SELECT 51, 'segments_sum_to_total', s.report_date, 'FAIL',
           s.portfolio_kzt = m.portfolio_kzt AND s.npl_kzt = m.npl_kzt AND s.provision_kzt = m.provision_kzt,
           format('%s: сегментов — %s; суммы портфеля, NPL и провизий равны итогу', s.segment_type, s.segments)
    FROM (
        SELECT report_date, segment_type, count(*) AS segments,
               sum(portfolio_kzt) AS portfolio_kzt, sum(npl_kzt) AS npl_kzt, sum(provision_kzt) AS provision_kzt
        FROM reporting.v_risk_by_segment
        GROUP BY 1, 2
    ) s
    JOIN m USING (report_date)

    UNION ALL
    SELECT 52, 'top10_groups', m.report_date, 'FAIL',
           g.top_groups = 10 AND g.top10_kzt = m.top10_groups_kzt AND m.top10_groups_kzt <= m.portfolio_kzt,
           format('топ-10 групп: %s%% портфеля; для сравнения топ-10 отдельных заёмщиков: %s%%',
                  round(m.top10_groups_ratio * 100, 2), round(b.top10_kzt / m.portfolio_kzt * 100, 2))
    FROM m
    JOIN (
        SELECT report_date, count(*) AS top_groups, sum(exposure_kzt) AS top10_kzt
        FROM reporting.v_group_exposure
        WHERE exposure_rank <= 10
        GROUP BY report_date
    ) g USING (report_date)
    JOIN (
        SELECT report_date, sum(exposure_kzt) AS top10_kzt
        FROM (
            SELECT report_date, sum(portfolio_kzt) AS exposure_kzt,
                   row_number() OVER (PARTITION BY report_date ORDER BY sum(portfolio_kzt) DESC, borrower_id) AS rnk
            FROM reporting.v_portfolio_clean
            GROUP BY report_date, borrower_id
        ) x
        WHERE rnk <= 10
        GROUP BY report_date
    ) b USING (report_date)

    UNION ALL
    SELECT 53, 'migration_complete', x.report_date, 'FAIL', x.in_matrix = y.on_both_dates,
           format('кредитов в матрице миграции: %s; есть на эту и прошлую дату: %s', x.in_matrix, y.on_both_dates)
    FROM (
        SELECT report_date, sum(loans) AS in_matrix FROM reporting.v_dpd_migration GROUP BY report_date
    ) x
    JOIN (
        SELECT c.report_date, count(*) AS on_both_dates
        FROM reporting.v_loan_snapshot c
        JOIN reporting.v_loan_snapshot p
          ON p.loan_id = c.loan_id
         AND p.report_date = (SELECT max(report_date) FROM reporting.v_loan_snapshot WHERE report_date < c.report_date)
        GROUP BY c.report_date
    ) y USING (report_date)

    -- 6. Согласованность данных между срезами (WARN) ------------------------------------

    UNION ALL
    SELECT 61, 'loan_attributes_stable', NULL, 'WARN', n = 0,
           format('кредитов, у которых между срезами поменялись заёмщик, группа, отрасль, программа, валюта или даты: %s', n)
    FROM (
        SELECT count(*) AS n
        FROM (
            SELECT loan_id
            FROM reporting.v_loan_snapshot
            GROUP BY loan_id
            HAVING count(DISTINCT (borrower_id, group_id, sector, program, currency, issue_date, maturity_date)) > 1
        ) x
    ) y

    UNION ALL
    SELECT 62, 'borrower_single_group', NULL, 'WARN', n = 0,
           format('заёмщиков в нескольких группах: %s', n)
    FROM (
        SELECT count(*) AS n
        FROM (
            SELECT borrower_id FROM reporting.v_loan_snapshot
            GROUP BY borrower_id HAVING count(DISTINCT group_id) > 1
        ) x
    ) y

    UNION ALL
    SELECT 62 + sort_order, rule, report_date, 'WARN', loans = 0,
           format('кредитов: %s, %s млрд ₸ (%s%% портфеля). Если «%s»: NPL %s%% → %s%%, PAR90 %s%% → %s%%, провизии %s → %s млрд ₸',
                  loans, round(amount_kzt / 1e9, 2), round(portfolio_share * 100, 2), lower(left(alternative, 1)) || substr(alternative, 2),
                  round(npl_ratio_reported * 100, 2), round(npl_ratio_alt * 100, 2),
                  round(par90_ratio_reported * 100, 2), round(par90_ratio_alt * 100, 2),
                  round(provision_kzt_reported / 1e9, 2), round(provision_kzt_alt / 1e9, 2))
    FROM reporting.v_data_quality_summary
),
-- Справочник: название проверки для людей и группа, в которой её показывать.
-- Для аномалий название берётся из v_data_quality_summary.
catalog (check_name, title, area) AS (
    VALUES
    ('raw_required_fields',          'Обязательные поля заполнены',                     'Исходные данные'),
    ('raw_value_domains',            'Флаги 0/1, просрочка и суммы не отрицательные',   'Исходные данные'),
    ('fx_unique_per_day',            'Один курс на день и валюту',                      'Исходные данные'),
    ('loan_unique_per_date',         'Одна строка на кредит и дату',                    'Исходные данные'),
    ('fx_rate_on_report_date',       'Курс есть именно на дату среза',                  'Курс'),
    ('reconcile_rows',               'Строки: raw = портфель + списанные + дубли',      'Сверка с источником'),
    ('reconcile_amount_by_currency', 'Суммы в валюте кредита совпадают с raw',          'Сверка с источником'),
    ('reconcile_portfolio_kzt',      'Портфель в тенге = raw × курс на дату',           'Сверка с источником'),
    ('risk_ordering',                'PAR90 ≤ PAR30 и PAR90 ≤ NPL',                     'Определения'),
    ('restructured_is_npl_50pct',    'Реструктуризированные — в NPL со ставкой 50%',    'Определения'),
    ('dpd_boundaries',               'Границы 30 и 90 дней — «строго больше»',          'Определения'),
    ('provision_bounds',             'Провизии от 1% до 50% портфеля',                  'Определения'),
    ('segments_sum_to_total',        'Разрезы в сумме дают итог',                       'Согласованность'),
    ('top10_groups',                 'Топ-10 — ровно 10 групп, сумма совпадает',        'Согласованность'),
    ('migration_complete',           'В матрице миграции все кредиты',                  'Согласованность'),
    ('loan_attributes_stable',       'Атрибуты кредита не меняются между срезами',      'Данные между срезами'),
    ('borrower_single_group',        'Заёмщик входит в одну группу',                    'Данные между срезами')
)
SELECT
    c.check_order,
    c.check_name,
    c.report_date,
    CASE WHEN coalesce(c.passed, false) THEN 'PASS' ELSE c.on_fail END AS status,
    c.details,
    coalesce(k.title, dq.title, c.check_name)                         AS title,
    coalesce(k.area, CASE WHEN dq.rule IS NOT NULL THEN 'Аномалии данных' END, 'Прочее') AS area
FROM checks c
LEFT JOIN catalog k ON k.check_name = c.check_name
LEFT JOIN (SELECT DISTINCT rule, title FROM reporting.v_data_quality_summary) dq ON dq.rule = c.check_name;
