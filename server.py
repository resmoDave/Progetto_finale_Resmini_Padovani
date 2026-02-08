# file: server_api.py
import sqlite3
import random
from fastapi import FastAPI, HTTPException

app = FastAPI()

# Configuration
DB_NAME = "server_emails.db"
DOMAINS = ["cloud-admin.it", "tech-support.com", "ops-team.net", "data-center.io"]

# Define the exact servers required
# 5 Web Servers
WEB_SERVERS = ["srv-web-01", "srv-web-02", "srv-web-03", "srv-web-04", "srv-web-05"]
# 3 Database Servers
DB_SERVERS = ["srv-db-01", "srv-db-02", "srv-db-03"]

# Combine them into one list (Total 8)
ALL_SERVERS = WEB_SERVERS + DB_SERVERS

def init_db():
    """
    Initializes the SQLite database.
    It drops the existing table to ensure we always have the clean list of 8 unique emails.
    """
    conn = sqlite3.connect(DB_NAME)
    cursor = conn.cursor()
    
    # Reset the table to ensure clean data generation
    cursor.execute("DROP TABLE IF EXISTS server_emails")
    
    # Create table with UNIQUE constraints
    cursor.execute("""
        CREATE TABLE server_emails (
            server_id TEXT PRIMARY KEY,
            email TEXT UNIQUE
        )
    """)
    
    print(f"--- GENERATING EMAILS FOR {len(ALL_SERVERS)} SERVERS ---")
    
    for server_id in ALL_SERVERS:
        if server_id == "srv-web-01":
            # 1. The specific requested email
            email = "marcopadovani06@gmail.com"
        else:
            # 2. Generate unique email for the others
            # Including the server_id in the string ensures it is 100% unique
            random.seed(server_id) 
            domain = random.choice(DOMAINS)
            email = f"admin.{server_id}@{domain}".lower()
        
        # Insert into SQLite
        try:
            cursor.execute("INSERT INTO server_emails (server_id, email) VALUES (?, ?)", (server_id, email))
            print(f" [OK] {server_id}: {email}")
        except sqlite3.IntegrityError:
            print(f" [ERR] Duplicate found for {server_id}")

    conn.commit()
    conn.close()
    print("--- DATABASE READY ---")

# Run DB initialization immediately when script starts
init_db()

@app.get("/get-email/{server_id}")
async def get_email(server_id: str):
    """
    Fetch the email for a specific server from the DB.
    """
    conn = sqlite3.connect(DB_NAME)
    cursor = conn.cursor()
    
    cursor.execute("SELECT email FROM server_emails WHERE server_id = ?", (server_id,))
    row = cursor.fetchone()
    conn.close()
    
    if row:
        return {"server_id": server_id, "email": row[0]}
    else:
        raise HTTPException(status_code=404, detail="Server ID not found in database")

@app.get("/all-emails")
async def get_all_emails():
    """
    Helper endpoint to see all generated emails at once.
    """
    conn = sqlite3.connect(DB_NAME)
    cursor = conn.cursor()
    cursor.execute("SELECT server_id, email FROM server_emails")
    rows = cursor.fetchall()
    conn.close()
    
    return [{"server_id": row[0], "email": row[1]} for row in rows]

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000)