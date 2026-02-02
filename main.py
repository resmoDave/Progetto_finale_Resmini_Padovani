import random
from datetime import datetime, timedelta

# Configurazione
OUTPUT_FILE = "backup.log"
NUM_LINES = 100

# Dati di esempio
HOSTNAMES = ["srv-web-01", "srv-db-01", "srv-file-02", "srv-mail-01"]
TYPES = ["FULL", "INCREMENTAL", "DIFFERENTIAL"]
OUTCOMES = ["SUCCESS", "SUCCESS", "SUCCESS", "SUCCESS", "WARNING", "ERROR"] # Pesa di più il successo

def generate_logs():
    logs = []
    # Data di partenza: 30 giorni fa
    current_time = datetime.now() - timedelta(days=30)

    print(f"Generazione di {NUM_LINES} righe di log in corso...")

    with open(OUTPUT_FILE, "w") as f:
        # Intestazione (opzionale nei log, ma utile per capire le colonne. 
        # Se vuoi un log puro stile Linux, commenta la riga sotto)
        # f.write("TIMESTAMP,HOSTNAME,TIPO_BACKUP,ESITO,DIMENSIONE_MB,DURATA_SEC\n")

        for _ in range(NUM_LINES):
            # 1. Avanza il tempo in modo casuale (tra 4 e 12 ore tra un log e l'altro)
            current_time += timedelta(hours=random.randint(4, 12), minutes=random.randint(0, 59))
            timestamp_str = current_time.strftime("%Y-%m-%d %H:%M:%S")

            # 2. Scelta Host e Tipo
            hostname = random.choice(HOSTNAMES)
            backup_type = random.choice(TYPES)

            # 3. Logica Dimensione e Durata (MB e Secondi)
            if backup_type == "FULL":
                size_mb = random.randint(50000, 200000) # 50GB - 200GB
                duration_sec = int(size_mb / random.randint(40, 60)) # Simulazione velocità scrittura
            elif backup_type == "DIFFERENTIAL":
                size_mb = random.randint(5000, 20000)   # 5GB - 20GB
                duration_sec = int(size_mb / random.randint(50, 70))
            else: # INCREMENTAL
                size_mb = random.randint(100, 2000)     # 100MB - 2GB
                duration_sec = int(size_mb / random.randint(60, 90))

            # Aggiusta durata minima
            if duration_sec < 1: duration_sec = 1

            # 4. Esito
            outcome = random.choice(OUTCOMES)
            
            # Se è errore, magari la dimensione è 0 o parziale (simulazione realistica)
            if outcome == "ERROR":
                size_mb = 0
                duration_sec = random.randint(1, 10)

            # 5. Scrittura riga (Formato CSV o spaziato? Qui uso separatore virgola per chiarezza)
            # Formato: TIMESTAMP,HOSTNAME,TIPO,ESITO,DIMENSIONE,DURATA
            log_line = f"{timestamp_str},{hostname},{backup_type},{outcome},{size_mb},{duration_sec}\n"
            f.write(log_line)

    print(f"Fatto! File creato: {OUTPUT_FILE}")

if __name__ == "__main__":
    generate_logs()