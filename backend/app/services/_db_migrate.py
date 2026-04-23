"""Run on import to ensure DB schema is up to date."""
import sqlite3, os
from pathlib import Path

def migrate():
    db_path = Path(__file__).parent.parent.parent.parent / "data" / "app.db"
    if not db_path.exists():
        return  # Will be created fresh by storage.py
    try:
        c = sqlite3.connect(str(db_path))
        cols = [row[1] for row in c.execute("PRAGMA table_info(maps)").fetchall()]
        if 'status' not in cols:
            c.execute("ALTER TABLE maps ADD COLUMN status TEXT DEFAULT 'draft'")
            c.commit()
        c.close()
    except Exception as e:
        print(f"DB migration warning: {e}")

migrate()
