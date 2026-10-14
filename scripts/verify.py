"""Независимый пересчёт метрик прямо из CSV — без SQL и без вьюх витрины.

Сверяет результат с тем, что loader выгрузил для дашборда (dashboard/data/*.json).
Суммы сравниваются точно (Decimal), доли — с допуском 1e-12. Любое расхождение — код выхода 1.
Только стандартная библиотека Python, чтобы проверка не зависела от окружения.
"""

import csv
import json
import sys
from collections import defaultdict
from datetime import date as Date
from decimal import Decimal
from pathlib import Path

DATA = Path("/data")
OUT = Path("/out")
RATIO_TOLERANCE = Decimal("1e-12")


def read_csv(name):
    with open(DATA / name, encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def load_json(name):
    with open(OUT / name, encoding="utf-8") as f:
        return json.load(f, parse_float=Decimal)


def dpd_bucket(dpd):
    return "0" if dpd == 0 else "1–30" if dpd <= 30 else "31–90" if dpd <= 90 else ">90"


def provision_rate(is_npl, dpd):
    if is_npl:
        return Decimal("0.50")
    if dpd > 30:
        return Decimal("0.10")
    return Decimal("0.01")


def compute():
    rows = read_csv("portfolio.csv")
    fx = {(r["date"], r["currency"].strip().upper()): Decimal(r["rate_kzt"]) for r in read_csv("fx.csv")}

    # Полные дубли строк схлопываем; ключ — все поля строки.
    unique = {tuple(r.items()): r for r in rows}.values()

    loans = []
    for r in unique:
        currency = r["currency"].strip().upper()
        date = r["report_date"]
        if currency == "KZT":
            rate = Decimal(1)
        elif (date, currency) in fx:
            rate = fx[(date, currency)]
        else:
            sys.exit(f"нет курса {currency} на {date} для {r['loan_id']}")
        dpd = int(r["days_past_due"])
        restructured = r["restructured"] == "1"
        is_npl = dpd > 90 or restructured
        kzt = Decimal(r["principal_outstanding"]) * rate
        loans.append({
            "date": date,
            "loan_id": r["loan_id"],
            "group_id": r["group_id"],
            "sector": r["sector"],
            "program": r["program"],
            "written_off": r["written_off"] == "1",
            "restructured": restructured,
            "maturity_date": r["maturity_date"],
            "dpd": dpd,
            "dpd_bucket": dpd_bucket(dpd),
            "kzt": kzt,
            "par30": kzt if dpd > 30 else Decimal(0),
            "par90": kzt if dpd > 90 else Decimal(0),
            "npl": kzt if is_npl else Decimal(0),
            "provision": kzt * provision_rate(is_npl, dpd),
        })

    live = [x for x in loans if not x["written_off"]]
    dates = sorted({x["date"] for x in loans})

    metrics = {}
    for d in dates:
        day = [x for x in live if x["date"] == d]
        groups = defaultdict(Decimal)
        for x in day:
            groups[x["group_id"]] += x["kzt"]
        top10 = sorted(groups.values(), reverse=True)[:10]
        portfolio = sum(x["kzt"] for x in day)
        metrics[d] = {
            "loans": len(day),
            "portfolio_kzt": portfolio,
            "par30_kzt": sum(x["par30"] for x in day),
            "par90_kzt": sum(x["par90"] for x in day),
            "npl_kzt": sum(x["npl"] for x in day),
            "provision_kzt": sum(x["provision"] for x in day),
            "top10_groups_kzt": sum(top10),
        }
        for k in ("par30", "par90", "npl", "provision"):
            metrics[d][f"{k}_ratio"] = metrics[d][f"{k}_kzt"] / portfolio
        metrics[d]["top10_groups_ratio"] = metrics[d]["top10_groups_kzt"] / portfolio

    segments = defaultdict(lambda: defaultdict(Decimal))
    for x in live:
        for seg_type in ("sector", "program", "dpd_bucket"):
            s = segments[(x["date"], seg_type, x[seg_type])]
            s["portfolio_kzt"] += x["kzt"]
            s["npl_kzt"] += x["npl"]
            s["provision_kzt"] += x["provision"]

    # Аномалии: списан в прошлом срезе и снова в портфеле; срок погашения прошёл,
    # а просрочка меньше числа дней после погашения; просрочка > 90 дней обнулилась
    # за один срез без реструктуризации.
    by_loan = defaultdict(dict)
    for x in loans:
        by_loan[x["loan_id"]][x["date"]] = x
    written_off_dates = defaultdict(set)
    for x in loans:
        if x["written_off"]:
            written_off_dates[x["loan_id"]].add(x["date"])
    issues = defaultdict(lambda: {"loans": 0, "amount_kzt": Decimal(0)})
    for x in live:
        if any(w < x["date"] for w in written_off_dates[x["loan_id"]]):
            issues[("written_off_reversed", x["date"])]["loans"] += 1
            issues[("written_off_reversed", x["date"])]["amount_kzt"] += x["kzt"]
        days_since = (Date.fromisoformat(x["date"]) - Date.fromisoformat(x["maturity_date"])).days
        if days_since > 0 and x["dpd"] < days_since:
            issues[("matured_dpd_inconsistent", x["date"])]["loans"] += 1
            issues[("matured_dpd_inconsistent", x["date"])]["amount_kzt"] += x["kzt"]
        earlier = [d for d in by_loan[x["loan_id"]] if d < x["date"]]
        if earlier:
            prev = by_loan[x["loan_id"]][max(earlier)]
            if prev["dpd"] > 90 and not prev["written_off"] and x["dpd"] == 0 and not x["restructured"]:
                issues[("dpd_reset_from_npl", x["date"])]["loans"] += 1
                issues[("dpd_reset_from_npl", x["date"])]["amount_kzt"] += x["kzt"]

    # Матрица миграции: состояние кредита на прошлую и текущую дату ('списан' — отдельное состояние).
    def state(x):
        return "списан" if x["written_off"] else x["dpd_bucket"]

    migration = defaultdict(lambda: {"loans": 0, "from_amount_kzt": Decimal(0)})
    for rows_by_date in by_loan.values():
        ds = sorted(rows_by_date)
        for prev_d, d in zip(ds, ds[1:]):
            prev, cur = rows_by_date[prev_d], rows_by_date[d]
            cell = migration[(d, state(prev), state(cur))]
            cell["loans"] += 1
            cell["from_amount_kzt"] += prev["kzt"]

    return dates, metrics, segments, issues, migration


def main():
    dates, metrics, segments, issues, migration = compute()
    failures = []

    def check(name, date, sql_value, py_value, tolerance=Decimal(0)):
        ok = abs(Decimal(sql_value) - Decimal(py_value)) <= tolerance
        if not ok:
            failures.append(f"{name} {date}: SQL {sql_value} ≠ Python {py_value}")
        return ok

    print("Независимый пересчёт из CSV (Python) против выгрузки витрины (SQL):")
    print(f"{'метрика':<22}" + "".join(f"{d:>26}" for d in dates))

    sql_metrics = {r["report_date"]: r for r in load_json("risk_metrics.json")}
    for name in ("loans", "portfolio_kzt", "par30_kzt", "par90_kzt", "npl_kzt", "provision_kzt",
                 "top10_groups_kzt", "par30_ratio", "par90_ratio", "npl_ratio", "provision_ratio",
                 "top10_groups_ratio"):
        tolerance = RATIO_TOLERANCE if name.endswith("_ratio") else Decimal(0)
        cells = []
        for d in dates:
            py = metrics[d][name]
            ok = check(name, d, sql_metrics[d][name], py, tolerance)
            if name.endswith("_ratio"):
                shown = f"{py * 100:.4f}%"
            elif isinstance(py, int):
                shown = str(py)
            else:
                shown = f"{py:,.2f}".replace(",", " ")
            cells.append(f"{shown} {'=' if ok else '≠'}")
        print(f"{name:<22}" + "".join(f"{c:>26}" for c in cells))

    sql_segments = load_json("risk_by_segment.json")
    if len(sql_segments) != len(segments):
        failures.append(f"разрезов в SQL {len(sql_segments)}, в Python {len(segments)}")
    for r in sql_segments:
        py = segments[(r["report_date"], r["segment_type"], r["segment"])]
        for k in ("portfolio_kzt", "npl_kzt", "provision_kzt"):
            check(f"{r['segment_type']}:{r['segment']}:{k}", r["report_date"], r[k], py[k])
    print(f"разрезы по отрасли, программе и корзине просрочки: {len(sql_segments)} строк, портфель, NPL и провизии")

    for r in load_json("data_quality.json"):
        py = issues[(r["rule"], r["report_date"])]
        check(f"{r['rule']}:loans", r["report_date"], r["loans"], py["loans"])
        check(f"{r['rule']}:amount_kzt", r["report_date"], r["amount_kzt"], py["amount_kzt"])
        print(f"аномалия {r['rule']} {r['report_date']}: кредитов — {py['loans']}")

    sql_migration = load_json("dpd_migration.json")
    if len(sql_migration) != len(migration):
        failures.append(f"ячеек матрицы миграции в SQL {len(sql_migration)}, в Python {len(migration)}")
    for r in sql_migration:
        py = migration[(r["report_date"], r["from_state"], r["to_state"])]
        cell = f"migration:{r['from_state']}→{r['to_state']}"
        check(f"{cell}:loans", r["report_date"], r["loans"], py["loans"])
        check(f"{cell}:from_amount_kzt", r["report_date"], r["from_amount_kzt"], py["from_amount_kzt"])
    print(f"матрица миграции: ячеек — {len(sql_migration)}, кредиты и суммы в каждой")

    if failures:
        print("\nРАСХОЖДЕНИЯ:")
        for f in failures:
            print("  " + f)
        sys.exit(1)
    print("\nOK: все цифры выгрузки совпадают с независимым пересчётом.")


if __name__ == "__main__":
    main()
