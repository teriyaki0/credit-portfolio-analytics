-- Очищенная витрина портфеля — источник для семантической модели и всех метрик.
-- Grain: loan_id × report_date, только не списанные кредиты.
--
-- Риск-суммы лежат отдельными колонками в тенге (par30_kzt, npl_kzt, provision_kzt),
-- а не долями: доли не аддитивны, их считаем как sum(числитель) / sum(portfolio_kzt)
-- на нужном уровне агрегации (дата, отрасль, программа).

CREATE OR REPLACE VIEW reporting.v_portfolio_clean AS
WITH live AS (
    SELECT
        s.*,
        -- 50% для NPL (в т.ч. реструктуризированных без просрочки), 10% при 31–90, 1% при 0–30.
        CASE
            WHEN s.is_npl             THEN 0.50
            WHEN s.days_past_due > 30 THEN 0.10
            ELSE 0.01
        END AS provision_rate
    FROM reporting.v_loan_snapshot s
    WHERE NOT s.is_written_off
)
SELECT
    report_date,
    loan_id,
    borrower_id,
    group_id,
    sector,
    program,
    currency,
    issue_date,
    maturity_date,
    principal_orig,
    fx_rate,
    days_past_due,
    dpd_bucket,
    is_restructured,
    is_par30,
    is_par90,
    is_npl,
    provision_rate,
    principal_kzt                                         AS portfolio_kzt,
    CASE WHEN is_par30 THEN principal_kzt ELSE 0 END      AS par30_kzt,
    CASE WHEN is_par90 THEN principal_kzt ELSE 0 END      AS par90_kzt,
    CASE WHEN is_npl   THEN principal_kzt ELSE 0 END      AS npl_kzt,
    principal_kzt * provision_rate                        AS provision_kzt
FROM live;
