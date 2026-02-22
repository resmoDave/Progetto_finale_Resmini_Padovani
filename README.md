
# Bash Rsync – Approfondimento tecnico

Questi script Bash fornisce un layer di automazione e controllo avanzato sopra Rsync, trasformando la gestione dei backup in un sistema robusto, monitorato e conforme alle policy aziendali e normative. Di seguito una panoramica tecnica delle funzionalità implementate:

---

## Caso d'Uso – contesto e motivazione

La documentazione completa del progetto è disponibile nel file [`ServerBackup - Marco Padovani, Davide Resmini.pdf`](ServerBackup%20-%20Marco%20Padovani%2C%20Davide%20Resmini.pdf).

---

## Come iniziare – Guida rapida

### Prerequisiti

Prima di eseguire qualsiasi script, assicurarsi che i seguenti strumenti siano disponibili sul sistema:

- `bash` (versione 4.0 o superiore)
- `rsync`
- `fuser` (parte del pacchetto `psmisc` sulla maggior parte delle distro Linux)
- `dd`, `chmod`, `kill` (utility Unix standard)
- `iptables` (richiesto da [`block_inactive_8.sh`](block_inactive_8.sh) – necessita dei permessi di root)
- Connessione internet attiva se si utilizzano le notifiche email tramite API

### Passo 1 – Generare i dati di test

Il punto di ingresso dell'intero sistema è [`generate.sh`](generate.sh). Questo script costruisce un ambiente di test realistico eseguendo le seguenti operazioni:

1. **Pulizia** di eventuali artefatti di esecuzioni precedenti (log, directory di backup, configurazione rsync).
2. **Avvio di un daemon rsync locale** sulla porta `9876` in ascolto su `127.0.0.1`, tramite un file `rsyncd.conf` temporaneo che espone un modulo `clients` puntato a una directory di storage simulata.
3. **Registrazione di un `trap`** affinché, all'uscita dello script (normale o per errore), il daemon venga terminato e il file di configurazione rimosso automaticamente.
4. **Simulazione di 8 server** (`srv-web-01` fino a `srv-web-05` e `srv-db-01` fino a `srv-db-03`), ognuno con un indirizzo IP casuale memorizzato in un array associativo.
5. **Esecuzione di 100 iterazioni di pull rsync**, in cui ogni iterazione:
   - Seleziona un server casuale.
   - Crea un file binario casuale (1–5 MB per i web server, 20–60 MB per i DB server) tramite `dd if=/dev/urandom`.
   - Sceglie uno scenario casuale: **errore di permessi** (10% di probabilità), **connessione interrotta** (10% di probabilità), oppure **trasferimento riuscito** (80% di probabilità).
   - Aggiunge una riga strutturata al file `rsync_master.log` nel formato: `TIMESTAMP [PID] IP (CLIENT) ITEMIZE FILENAME SIZE`.

Per eseguirlo:

```bash
chmod +x generate.sh
./generate.sh
```

Al termine, il file `rsync_master.log` sarà popolato e pronto per essere elaborato da tutti gli altri script.

### Passo 2 – Eseguire gli script di elaborazione

Ogni script è indipendente e legge da `rsync_master.log` (o dal log strutturato prodotto da [`Refactoring_Log_1.sh`](Refactoring_Log_1.sh)). L'ordine di esecuzione consigliato è:

1. [`./Refactoring_Log_1.sh`](Refactoring_Log_1.sh)
2. [`./Warn_Client_2.sh`](Warn_Client_2.sh)
3. [`./Manutenzione_Log_3.sh`](Manutenzione_Log_3.sh)
4. [`./Quota_Killer_4.sh`](Quota_Killer_4.sh)
5. [`./split_logs_by_id_5.sh`](split_logs_by_id_5.sh)
6. [`./clean_up_6.sh`](clean_up_6.sh)
7. [`./backup_warn_7.sh`](backup_warn_7.sh)
8. [`./block_inactive_8.sh`](block_inactive_8.sh)
9. [`./payment_enforcer_9.sh`](payment_enforcer_9.sh)
10. [`./full_verification_10.sh`](full_verification_10.sh)

Per rendere tutti gli script eseguibili in un solo comando:

```bash
chmod +x *.sh
```

### Server API Python – [`server.py`](server.py)

Il file [`server.py`](server.py) implementa un'API REST leggera basata su **FastAPI** che funge da registro centralizzato dei server e delle loro email di contatto. Viene avviata prima degli script Bash e rimane in ascolto su `http://127.0.0.1:8000`.

All'avvio, il server:

1. **Inizializza un database SQLite** (`server_emails.db`) con una tabella `server_emails` contenente tre colonne: `server_id`, `email` e `active`.
2. **Popola il database** con i dati di tutti e 8 i server simulati. Il server `srv-web-01` viene marcato come **inattivo** (`active = 0`) e associato a un indirizzo email reale; tutti gli altri server sono attivi e ricevono un'email generata deterministicamente dal loro ID.
3. **Espone due endpoint HTTP**:
   - `GET /get-email/{server_id}` – restituisce email e stato di attività per un singolo server; risponde con `404` se l'ID non esiste.
   - `GET /all-emails` – restituisce la lista completa di tutti i server con email e stato.

Gli script Bash che inviano notifiche o verificano lo stato di pagamento interrogano questa API per ottenere l'indirizzo email del destinatario e sapere se il server è attivo o non pagante.

Per avviare il server:

```bash
pip install fastapi uvicorn
python server.py
```

Il server rimarrà in esecuzione in background mentre si eseguono gli script Bash.

---

## 1. Refactoring e normalizzazione log
Lo script effettua l'esecuzione/scansione dati in tempo reale del log Rsync, riconoscendo automaticamente le colonne chiave (timestamp, PID, host/IP, dimensione, percorso, esito). Genera un file di audit strutturato, facilitando l’analisi e l’integrazione con altri moduli. Supporta configurazioni personalizzate e filtra i dati per una reportistica precisa.
📂 **Script:** [Refactoring_Log_1.sh](Refactoring_Log_1.sh)

## 2. Adattabilità automatica e notifiche
Monitoraggio continuo del log di backup. In caso di errori di connessione o permessi, il sistema intercetta l’evento, lo inserisce in una coda e invia notifiche email al cliente tramite API. Il worker gestisce la coda, garantendo la consegna delle notifiche anche in caso di errori temporanei.
📂 **Script:** [Warn_Client_2.sh](Warn_Client_2.sh)

## 3. Manutenzione log
Gestione automatica dei file di log: compressione e archiviazione. Mantiene solo gli ultimi archivi per risparmiare spazio, con estrazione rapida dei log compressi. La pulizia è selettiva per evitare la perdita di dati rilevanti.
📂 **Script:** [Manutenzione_Log_3.sh](Manutenzione_Log_3.sh)

## 4. Controllo quote e prevenzione abusi
Monitoraggio in tempo reale delle dimensioni dei trasferimenti. Se un processo supera la quota configurata, viene terminato automaticamente. Il sistema verifica che il PID sia attivo prima di eseguire il kill, garantendo la protezione dello storage.
📂 **Script:** [Quota_Killer_4.sh](Quota_Killer_4.sh)

## 5. Organizzazione per cliente
Separazione automatica dei log per cliente: il sistema estrae solo le voci relative a uno specifico ID cliente, con la possibilità di applicare anche filtri temporali. Per ogni cliente viene generato un file di log dedicato, rendendo più semplici le attività di troubleshooting e controllo.
📂 **Script:** [split_logs_by_id_5.sh](split_logs_by_id_5.sh)

## 6. Cleanup dello storage 
Esecuzione periodica di garbage collection. Rimozione di file temporanei e parziali. Analizza i log per individuare backup obsoleti e directory vuote, ruota e comprime i log, verifica errori ricorrenti e integrità dello storage.
📂 **Script:** [clean_up_6.sh](clean_up_6.sh)

## 7. Verifica backup e continuità operativa 
Verifica automatica che ogni cliente abbia almeno un backup completo valido negli ultimi 7 giorni. In caso di mancanza, invia una notifica di alert. 
📂 **Script:** [backup_warn_7.sh](backup_warn_7.sh)

## 8. Sicurezza accessi 
Analisi del log di audit e verifica dello stato di ogni server tramite API. Blocca con iptables gli IP dei client non attivi (non paganti). Gestisce la whitelist e previene accessi non autorizzati.
📂 **Script:** [block_inactive_8.sh](block_inactive_8.sh)

## 9. Gestione insoluti e recupero crediti
Integrazione con lo stato dei pagamenti. Invio automatico di solleciti email in caso di inadempienza, tracciamento dello stato di inattività, cancellazione sicura dei dati dopo un periodo definito di insolvenza. Tutto il processo è loggato e tracciato.
📂 **Script:** [payment_enforcer_9.sh](payment_enforcer_9.sh)

## 10. Audit totale e integrità
Verifica fisica di tutti i file di backup contrassegnati come SUCCESS nel log. Controlla esistenza, leggibilità e dimensione effettiva dei file. In caso di errori, invia una email di riepilogo per ogni server con problemi rilevati.
📂 **Script:** [full_verification_10.sh](full_verification_10.sh)

