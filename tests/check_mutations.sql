-- Мутационные тесты проверок. В каждой транзакции вносим в витрину или данные типичную
-- ошибку и требуем, чтобы reporting.v_checks её поймал (FAIL); затем ROLLBACK.
-- Проверка, которая не падает на заведомо неверных цифрах, ничего не доказывает.
--
-- Вьюхи мутируем через их сохранённый текст (pg_get_viewdef + replace), а не копией SQL:
-- тест ломает ровно одну строку настоящей витрины.

\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

CREATE FUNCTION pg_temp.mutate_view(view_name text, old_text text, new_text text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    def text := pg_get_viewdef(view_name::regclass);
BEGIN
    IF position(old_text IN def) = 0 THEN
        RAISE EXCEPTION 'мутация не применилась: в % нет «%»', view_name, old_text;
    END IF;
    EXECUTE format('CREATE OR REPLACE VIEW %s AS %s', view_name, replace(def, old_text, new_text));
END
$$;

CREATE FUNCTION pg_temp.expect_fail(title text, expected_check text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    found text;
BEGIN
    SELECT string_agg(coalesce(to_char(report_date, 'DD.MM.YYYY'), 'все даты') || ': ' || details, '; '
                      ORDER BY report_date)
      INTO found
      FROM reporting.v_checks
     WHERE check_name = expected_check AND status = 'FAIL';
    IF found IS NULL THEN
        RAISE EXCEPTION 'НЕ ПОЙМАНО: «%» — проверка % не упала', title, expected_check;
    END IF;
    RETURN format('OK   %s → FAIL %s — %s', title, expected_check, found);
END
$$;

\echo 'Мутационные тесты: каждая типичная ошибка должна уронить свою проверку'

BEGIN;
SELECT pg_temp.mutate_view('reporting.v_loan_snapshot',
    'SELECT DISTINCT portfolio.report_date', 'SELECT portfolio.report_date') \g /dev/null
SELECT pg_temp.expect_fail('дубли строк не убраны', 'loan_unique_per_date');
ROLLBACK;

BEGIN;
SELECT pg_temp.mutate_view('reporting.v_loan_snapshot',
    'fx.date = b.report_date', 'fx.date = (SELECT max(f2.date) FROM raw.fx f2)') \g /dev/null
SELECT pg_temp.expect_fail('курс на последнюю дату в файле вместо даты среза', 'reconcile_portfolio_kzt');
ROLLBACK;

BEGIN;
DELETE FROM raw.fx WHERE date = '2026-10-01';
SELECT pg_temp.expect_fail('в fx.csv нет курса на дату среза', 'fx_rate_on_report_date');
ROLLBACK;

BEGIN;
SELECT pg_temp.mutate_view('reporting.v_portfolio_clean',
    'WHERE (NOT s.is_written_off)', 'WHERE true') \g /dev/null
SELECT pg_temp.expect_fail('списанные кредиты остались в портфеле', 'reconcile_rows');
ROLLBACK;

BEGIN;
SELECT pg_temp.mutate_view('reporting.v_loan_snapshot',
    '((days_past_due > 90) OR is_restructured) AS is_npl', '(days_past_due > 90) AS is_npl') \g /dev/null
SELECT pg_temp.expect_fail('NPL только по просрочке, без реструктуризированных', 'restructured_is_npl_50pct');
ROLLBACK;

BEGIN;
CREATE OR REPLACE FUNCTION reporting.provision_rate(is_npl boolean, days_past_due integer)
RETURNS numeric LANGUAGE sql IMMUTABLE
AS $$ SELECT CASE WHEN days_past_due > 90 THEN 0.50 WHEN days_past_due > 30 THEN 0.10 ELSE 0.01 END $$;
SELECT pg_temp.expect_fail('ставка провизии по просрочке, без учёта NPL', 'restructured_is_npl_50pct');
ROLLBACK;

BEGIN;
SELECT pg_temp.mutate_view('reporting.v_loan_snapshot',
    '(days_past_due > 90) AS is_par90', '(days_past_due >= 90) AS is_par90') \g /dev/null
SELECT pg_temp.expect_fail('PAR90 как «90 дней и больше»', 'dpd_boundaries');
ROLLBACK;

BEGIN;
INSERT INTO raw.portfolio
SELECT report_date, loan_id, borrower_id, group_id, sector, program, currency, issue_date,
       maturity_date, principal_outstanding + 1, days_past_due, restructured, written_off
FROM raw.portfolio
WHERE report_date = '2026-10-01'
ORDER BY loan_id
LIMIT 1;
SELECT pg_temp.expect_fail('две разные строки одного кредита на дату', 'loan_unique_per_date');
ROLLBACK;
