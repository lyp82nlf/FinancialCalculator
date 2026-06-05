#!/usr/bin/env python3
import json
import os
import re
import sqlite3
import sys
from datetime import datetime


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_FILE = os.environ.get("FINANCE_DB_FILE") or os.path.join(BASE_DIR, "finance.db")
MONTH_RE = re.compile(r"^\d{4}-\d{2}$")


def connect():
    conn = sqlite3.connect(DB_FILE)
    conn.row_factory = sqlite3.Row
    return conn


def now_iso():
    return datetime.now().isoformat(timespec="seconds")


def read_payload():
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    return json.loads(raw)


def write_json(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=False))


def init_db(conn):
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS monthly_snapshots (
          month_key TEXT PRIMARY KEY,
          config_json TEXT NOT NULL,
          summary_json TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS snapshot_investment_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          month_key TEXT NOT NULL,
          assignee_id TEXT,
          assignee_name TEXT,
          category_name TEXT,
          subcategory_name TEXT,
          item_name TEXT NOT NULL,
          monthly_amount REAL NOT NULL,
          daily_amount REAL,
          trading_days INTEGER,
          is_estimated_trading_days INTEGER NOT NULL DEFAULT 0,
          FOREIGN KEY (month_key) REFERENCES monthly_snapshots(month_key)
            ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS snapshot_member_balances (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          month_key TEXT NOT NULL,
          member_id TEXT,
          member_name TEXT NOT NULL,
          income REAL NOT NULL,
          target REAL NOT NULL,
          balance REAL NOT NULL,
          FOREIGN KEY (month_key) REFERENCES monthly_snapshots(month_key)
            ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_snapshot_items_month
          ON snapshot_investment_items(month_key);
        CREATE INDEX IF NOT EXISTS idx_snapshot_items_assignee
          ON snapshot_investment_items(assignee_name);
        CREATE INDEX IF NOT EXISTS idx_snapshot_items_name
          ON snapshot_investment_items(item_name);
        """
    )
    conn.commit()


def require_month(month_key):
    if not MONTH_RE.match(month_key or ""):
        raise ValueError("invalid monthKey")
    return month_key


def save_current(conn, payload):
    month_key = require_month(payload.get("monthKey"))
    config = payload.get("config") or {}
    summary = payload.get("summary") or {}
    investment_items = payload.get("investmentItems") or []
    member_balances = payload.get("memberBalances") or []
    stamp = now_iso()

    with conn:
        exists = conn.execute(
            "SELECT 1 FROM monthly_snapshots WHERE month_key = ?",
            (month_key,),
        ).fetchone()
        created_at = stamp
        if exists:
            created = conn.execute(
                "SELECT created_at FROM monthly_snapshots WHERE month_key = ?",
                (month_key,),
            ).fetchone()
            created_at = created["created_at"] if created else stamp

        conn.execute(
            """
            INSERT INTO monthly_snapshots
              (month_key, config_json, summary_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(month_key) DO UPDATE SET
              config_json = excluded.config_json,
              summary_json = excluded.summary_json,
              updated_at = excluded.updated_at
            """,
            (
                month_key,
                json.dumps(config, ensure_ascii=False),
                json.dumps(summary, ensure_ascii=False),
                created_at,
                stamp,
            ),
        )
        conn.execute(
            "DELETE FROM snapshot_investment_items WHERE month_key = ?",
            (month_key,),
        )
        conn.execute(
            "DELETE FROM snapshot_member_balances WHERE month_key = ?",
            (month_key,),
        )

        for item in investment_items:
            conn.execute(
                """
                INSERT INTO snapshot_investment_items
                  (month_key, assignee_id, assignee_name, category_name,
                   subcategory_name, item_name, monthly_amount, daily_amount,
                   trading_days, is_estimated_trading_days)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    month_key,
                    item.get("assigneeId") or "",
                    item.get("assigneeName") or "",
                    item.get("categoryName") or "",
                    item.get("subcategoryName") or "",
                    item.get("itemName") or "未命名投资项",
                    float(item.get("monthlyAmount") or 0),
                    None
                    if item.get("dailyAmount") is None
                    else float(item.get("dailyAmount") or 0),
                    None
                    if item.get("tradingDays") is None
                    else int(item.get("tradingDays") or 0),
                    1 if item.get("isEstimatedTradingDays") else 0,
                ),
            )

        for balance in member_balances:
            conn.execute(
                """
                INSERT INTO snapshot_member_balances
                  (month_key, member_id, member_name, income, target, balance)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    month_key,
                    balance.get("memberId") or "",
                    balance.get("memberName") or "未命名成员",
                    float(balance.get("income") or 0),
                    float(balance.get("target") or 0),
                    float(balance.get("balance") or 0),
                ),
            )

    return {"ok": True, "monthKey": month_key, "updated": bool(exists)}


def get_current(conn, payload):
    month_key = require_month(payload.get("monthKey"))
    row = conn.execute(
        "SELECT * FROM monthly_snapshots WHERE month_key = ?",
        (month_key,),
    ).fetchone()
    if not row:
        return {"ok": False, "error": "snapshot_not_found"}

    return {
        "ok": True,
        "snapshot": {
            "monthKey": row["month_key"],
            "config": json.loads(row["config_json"]),
            "summary": json.loads(row["summary_json"]),
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
        },
    }


def rows_to_dicts(rows):
    return [dict(row) for row in rows]


def add_group(target, key, amount, daily):
    if key not in target:
        target[key] = {
            "name": key,
            "monthlyAmount": 0,
            "dailyAmountTotal": 0,
            "dailyAmountCount": 0,
            "itemCount": 0,
        }
    target[key]["monthlyAmount"] += amount
    target[key]["itemCount"] += 1
    if daily is not None:
        target[key]["dailyAmountTotal"] += daily
        target[key]["dailyAmountCount"] += 1


def finalize_groups(group_map):
    result = []
    for item in group_map.values():
        count = item.pop("dailyAmountCount")
        total = item.pop("dailyAmountTotal")
        item["averageDailyAmount"] = round(total / count) if count else None
        item["monthlyAmount"] = round(item["monthlyAmount"])
        result.append(item)
    return result


def history(conn, payload):
    where = []
    params = []
    year = (payload.get("year") or "").strip()
    month = (payload.get("month") or "").strip()
    assignee = (payload.get("assignee") or "").strip()
    item_keyword = (payload.get("itemKeyword") or "").strip()

    if year:
        where.append("substr(month_key, 1, 4) = ?")
        params.append(year)
    if month:
        month = month.zfill(2)
        if year:
            where.append("month_key = ?")
            params.append(f"{year}-{month}")
        else:
            where.append("substr(month_key, 6, 2) = ?")
            params.append(month)
    if assignee:
        where.append("assignee_name = ?")
        params.append(assignee)
    if item_keyword:
        where.append("item_name LIKE ?")
        params.append(f"%{item_keyword}%")

    sql = "SELECT * FROM snapshot_investment_items"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY month_key DESC, assignee_name, item_name"

    rows = rows_to_dicts(conn.execute(sql, params).fetchall())
    items = []
    months = set()
    total_amount = 0
    daily_total = 0
    daily_count = 0
    grouped_by_assignee = {}
    grouped_by_item = {}
    grouped_by_month = {}

    for row in rows:
        monthly_amount = float(row["monthly_amount"] or 0)
        daily_amount = (
            None
            if row["daily_amount"] is None
            else float(row["daily_amount"] or 0)
        )
        months.add(row["month_key"])
        total_amount += monthly_amount
        if daily_amount is not None:
            daily_total += daily_amount
            daily_count += 1

        assignee_name = row["assignee_name"] or "未指派"
        item_name = row["item_name"] or "未命名投资项"
        add_group(grouped_by_assignee, assignee_name, monthly_amount, daily_amount)
        add_group(grouped_by_item, item_name, monthly_amount, daily_amount)
        add_group(grouped_by_month, row["month_key"], monthly_amount, daily_amount)

        items.append(
            {
                "monthKey": row["month_key"],
                "assigneeName": assignee_name,
                "categoryName": row["category_name"] or "",
                "subcategoryName": row["subcategory_name"] or "",
                "itemName": item_name,
                "monthlyAmount": round(monthly_amount),
                "dailyAmount": None if daily_amount is None else round(daily_amount),
                "tradingDays": row["trading_days"],
                "isEstimatedTradingDays": bool(row["is_estimated_trading_days"]),
            }
        )

    filter_rows = conn.execute(
        """
        SELECT DISTINCT month_key FROM snapshot_investment_items
        ORDER BY month_key DESC
        """
    ).fetchall()
    filter_months = [row["month_key"] for row in filter_rows]
    filter_years = sorted({m[:4] for m in filter_months}, reverse=True)
    filter_assignees = [
        row["assignee_name"]
        for row in conn.execute(
            """
            SELECT DISTINCT assignee_name
            FROM snapshot_investment_items
            WHERE assignee_name IS NOT NULL AND assignee_name != ''
            ORDER BY assignee_name
            """
        ).fetchall()
    ]

    return {
        "ok": True,
        "items": items,
        "summary": {
            "totalInvestment": round(total_amount),
            "averageDailyAmount": round(daily_total / daily_count)
            if daily_count
            else None,
            "monthCount": len(months),
            "itemCount": len(items),
        },
        "groupedByAssignee": finalize_groups(grouped_by_assignee),
        "groupedByItem": finalize_groups(grouped_by_item),
        "groupedByMonth": finalize_groups(grouped_by_month),
        "filters": {
            "years": filter_years,
            "months": filter_months,
            "assignees": filter_assignees,
        },
    }


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "init"
    payload = read_payload()
    conn = connect()
    init_db(conn)

    if command == "init":
        result = {"ok": True}
    elif command == "save-current":
        result = save_current(conn, payload)
    elif command == "get-current":
        result = get_current(conn, payload)
    elif command == "history":
        result = history(conn, payload)
    else:
        raise ValueError(f"unknown command: {command}")

    write_json(result)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        write_json({"ok": False, "error": str(exc)})
        sys.exit(1)
