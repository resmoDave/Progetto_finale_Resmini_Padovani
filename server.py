# file: server_api.py
import sqlite3
import random
from fastapi import FastAPI, HTTPException

app = FastAPI()

DB_NAME = "server_emails.db"
DOMAINS = ["cloud-admin.it", "tech-support.com", "ops-team.net", "data-center.io"]

# Server attivi (quelli che pagano) – tutti tranne srv-web-01
WEB_SERVERS = ["srv-web-01", "srv-web-02", "srv-web-03", "srv-web-04", "srv-web-05"]
DB_SERVERS  = ["srv-db-01", "srv-db-02", "srv-db-03"]
ALL_SERVERS = WEB_SERVERS + DB_SERVERS  # 8 server totali

def init_db():
    conn = sqlite3.connect(DB_NAME)
    cursor = conn.cursor()

    cursor.execute("DROP TABLE IF EXISTS server_emails")
    cursor.execute("""
        CREATE TABLE server_emails (
            server_id TEXT PRIMARY KEY,
            email TEXT UNIQUE,
            active INTEGER DEFAULT 1
        )
    """)

    print(f"--- GENERAZIONE EMAIL PER {len(ALL_SERVERS)} SERVER ---")
    for server_id in ALL_SERVERS:
        if server_id == "srv-web-01":
            email = "padovanimarco488@gmail.com"
            active = 0   # ⚠️ NON ATTIVO (non pagante)
        else:
            random.seed(server_id)
            domain = random.choice(DOMAINS)
            email = f"admin.{server_id}@{domain}".lower()
            active = 1

        try:
            cursor.execute(
                "INSERT INTO server_emails (server_id, email, active) VALUES (?, ?, ?)",
                (server_id, email, active)
            )
            stato = "INATTIVO" if active == 0 else "ATTIVO"
            print(f" [{stato}] {server_id}: {email}")
        except sqlite3.IntegrityError:
            print(f" [ERR] Duplicato per {server_id}")

    conn.commit()
    conn.close()
    print("--- DATABASE PRONTO ---")

init_db()

@app.get("/get-email/{server_id}")
async def get_email(server_id: str):
    conn = sqlite3.connect(DB_NAME)
    cursor = conn.cursor()
    cursor.execute("SELECT email, active FROM server_emails WHERE server_id = ?", (server_id,))
    row = cursor.fetchone()
    conn.close()
    if row:
        return {"server_id": server_id, "email": row[0], "active": row[1]}
    raise HTTPException(status_code=404, detail="Server ID not found")

@app.get("/all-emails")
async def get_all_emails():
    conn = sqlite3.connect(DB_NAME)
    cursor = conn.cursor()
    cursor.execute("SELECT server_id, email, active FROM server_emails")
    rows = cursor.fetchall()
    conn.close()
    return [{"server_id": r[0], "email": r[1], "active": r[2]} for r in rows]

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000)