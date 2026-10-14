-- raw = файлы как есть: без дедупликации, фильтров и пересчётов.
-- Повторный запуск перезаливает таблицы целиком (TRUNCATE + COPY в одной транзакции).

CREATE TABLE IF NOT EXISTS raw.portfolio (
    report_date           date           NOT NULL,
    loan_id               text           NOT NULL,
    borrower_id           text,
    group_id              text,
    sector                text,
    program               text,
    currency              text,
    issue_date            date,
    maturity_date         date,
    principal_outstanding numeric(20, 2),
    days_past_due         integer,
    restructured          smallint,
    written_off           smallint
);

CREATE TABLE IF NOT EXISTS raw.fx (
    date     date           NOT NULL,
    currency text           NOT NULL,
    rate_kzt numeric(12, 4) NOT NULL
);

BEGIN;
TRUNCATE raw.portfolio, raw.fx;
\copy raw.portfolio FROM '/data/portfolio.csv' WITH (FORMAT csv, HEADER true)
\copy raw.fx FROM '/data/fx.csv' WITH (FORMAT csv, HEADER true)
COMMIT;
