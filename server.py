# file: server_api.py
from fastapi import FastAPI
import random

app = FastAPI()

# Domini casuali per l'esempio
DOMINI = ["cloud-admin.it", "tech-support.com", "ops-team.net"]

@app.get("/get-email/{server_id}")
async def get_email(server_id: str):
    # Genera un'email fissa per lo stesso server usando un seed
    random.seed(server_id) 
    dominio = random.choice(DOMINI)
    return {"email": f"admin.{server_id}@{dominio}".lower()}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000)