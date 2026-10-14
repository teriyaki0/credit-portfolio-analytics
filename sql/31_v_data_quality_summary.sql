-- Сводка по аномалиям: сколько кредитов и денег затронуто и как изменились бы метрики
-- при альтернативной трактовке. Grain: rule × report_date (правило без находок — строка с нулями).
-- Метрики в отчёте считаются по колонкам *_reported; *_alt — только оценка чувствительности.

CREATE OR REPLACE VIEW reporting.v_data_quality_summary AS
WITH rules (sort_order, rule, severity, title, treatment, alternative, question) AS (
    VALUES
    (1, 'written_off_reversed', 'WARN',
        'Списан в прошлом срезе, снова в портфеле',
        'В портфеле по флагу на дату среза, как в определении',
        'Списание верное: кредита в портфеле нет',
        'Списание отменено или флаг в прошлом срезе ошибочный?'),
    (2, 'matured_dpd_inconsistent', 'WARN',
        'Срок погашения прошёл, просрочка меньше дней после погашения',
        'Просрочка как в выгрузке',
        'Просрочка считается с даты погашения',
        'Были ли пролонгации, не отражённые в maturity_date, или просрочка выгружается неверно?')
),
issues AS (
    SELECT
        rule,
        report_date,
        count(*)                                AS loans,
        sum(portfolio_kzt)                      AS amount_kzt,
        sum(alt_portfolio_kzt - portfolio_kzt)  AS d_portfolio_kzt,
        sum(alt_par30_kzt     - par30_kzt)      AS d_par30_kzt,
        sum(alt_par90_kzt     - par90_kzt)      AS d_par90_kzt,
        sum(alt_npl_kzt       - npl_kzt)        AS d_npl_kzt,
        sum(alt_provision_kzt - provision_kzt)  AS d_provision_kzt
    FROM reporting.v_data_quality_issues
    GROUP BY rule, report_date
),
joined AS (
    SELECT
        r.*,
        m.report_date,
        m.portfolio_kzt,
        m.par30_kzt,
        m.par90_kzt,
        m.npl_kzt,
        m.provision_kzt,
        coalesce(i.loans, 0)            AS loans,
        coalesce(i.amount_kzt, 0)       AS amount_kzt,
        coalesce(i.d_portfolio_kzt, 0)  AS d_portfolio_kzt,
        coalesce(i.d_par30_kzt, 0)      AS d_par30_kzt,
        coalesce(i.d_par90_kzt, 0)      AS d_par90_kzt,
        coalesce(i.d_npl_kzt, 0)        AS d_npl_kzt,
        coalesce(i.d_provision_kzt, 0)  AS d_provision_kzt
    FROM rules r
    CROSS JOIN reporting.v_risk_metrics m
    LEFT JOIN issues i ON i.rule = r.rule AND i.report_date = m.report_date
)
SELECT
    sort_order,
    rule,
    severity,
    title,
    report_date,
    loans,
    amount_kzt,
    amount_kzt / portfolio_kzt                                      AS portfolio_share,
    treatment,
    alternative,
    question,
    portfolio_kzt                                                   AS portfolio_kzt_reported,
    portfolio_kzt + d_portfolio_kzt                                 AS portfolio_kzt_alt,
    par30_kzt / portfolio_kzt                                       AS par30_ratio_reported,
    (par30_kzt + d_par30_kzt) / (portfolio_kzt + d_portfolio_kzt)   AS par30_ratio_alt,
    par90_kzt / portfolio_kzt                                       AS par90_ratio_reported,
    (par90_kzt + d_par90_kzt) / (portfolio_kzt + d_portfolio_kzt)   AS par90_ratio_alt,
    npl_kzt / portfolio_kzt                                         AS npl_ratio_reported,
    (npl_kzt + d_npl_kzt) / (portfolio_kzt + d_portfolio_kzt)       AS npl_ratio_alt,
    provision_kzt                                                   AS provision_kzt_reported,
    provision_kzt + d_provision_kzt                                 AS provision_kzt_alt
FROM joined;
