#!/bin/sh
# Применяет sql/*.sql в лексикографическом порядке. Каждый файл идемпотентен.
set -eu

for f in /sql/*.sql; do
  echo "==> $f"
  psql -v ON_ERROR_STOP=1 -q -f "$f"
done

# Полнота загрузки: в raw должно оказаться ровно столько строк, сколько в CSV (без заголовка).
check_rows() {
  table=$1
  file=$2
  in_csv=$(($(wc -l < "$file") - 1))
  in_db=$(psql -tA -c "SELECT count(*) FROM $table")
  if [ "$in_csv" -ne "$in_db" ]; then
    echo "FAIL $table: строк в CSV — $in_csv, в базе — $in_db"
    exit 1
  fi
  echo "OK   $table: строк в базе — $in_db, как в CSV"
}

check_rows raw.portfolio /data/portfolio.csv
check_rows raw.fx /data/fx.csv

echo
psql -P pager=off -P footer=off -c "
  SELECT status, check_name, to_char(report_date, 'DD.MM.YYYY') AS date, details
  FROM reporting.v_checks
  ORDER BY check_order, report_date NULLS FIRST, details"

fails=$(psql -tA -c "SELECT count(*) FROM reporting.v_checks WHERE status = 'FAIL'")
warns=$(psql -tA -c "SELECT count(*) FROM reporting.v_checks WHERE status = 'WARN'")
if [ "$fails" -ne 0 ]; then
  echo "Проверки не пройдены: FAIL — $fails. Цифры витрины публиковать нельзя."
  exit 1
fi
echo "Проверки пройдены. Предупреждений: $warns (кредиты — reporting.v_data_quality_issues)."

# Проверка проверок: типичные ошибки должны ронять свои проверки (всё откатывается).
echo
psql -q -f /tests/check_mutations.sql

# Выгрузка для дашборда — только после пройденных проверок. Порядок строк фиксирован,
# поэтому повторный запуск даёт те же файлы (git diff пустой).
export_json() {
  file=$1
  query=$2
  order=$3
  psql -tA -c "SELECT jsonb_pretty(coalesce(jsonb_agg(t ORDER BY $order), '[]'::jsonb)) FROM ($query) t" > "/out/$file"
  echo "OK   /out/$file"
}

echo
export_json risk_metrics.json        "SELECT * FROM reporting.v_risk_metrics" "report_date"
export_json risk_metrics_change.json "SELECT * FROM reporting.v_risk_metrics_change" "report_date, sort_order"
export_json risk_by_segment.json     "SELECT * FROM reporting.v_risk_by_segment" "segment_type, segment, report_date"
export_json top_groups.json          "SELECT * FROM reporting.v_group_exposure WHERE exposure_rank <= 10" "report_date, exposure_rank"
export_json data_quality.json        "SELECT * FROM reporting.v_data_quality_summary" "sort_order, report_date"
export_json checks.json              "SELECT * FROM reporting.v_checks" "check_order, report_date NULLS FIRST, details"
