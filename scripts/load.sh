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
