
# Bash Rsync – Approfondimento tecnico

Questi script Bash fornisce un layer di automazione e controllo avanzato sopra Rsync, trasformando la gestione dei backup in un sistema robusto, monitorato e conforme alle policy aziendali e normative. Di seguito una panoramica tecnica delle funzionalità implementate:

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

### Passo 1 – Generare i dati di Test

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

### Passo 2 – Eseguire gli Script di Elaborazione

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

---

## 1. Refactoring e Normalizzazione Log
Lo script effettua il parsing in tempo reale del log Rsync, riconoscendo automaticamente le colonne chiave (timestamp, PID, host/IP, dimensione, percorso, esito). Genera un file di audit strutturato, facilitando l’analisi e l’integrazione con altri moduli. Supporta configurazioni personalizzate e filtra i dati per una reportistica precisa.
📂 **Script:** [Refactoring_Log_1.sh](Refactoring_Log_1.sh)

## 2. Resilienza Automatica e Notifiche
Monitoraggio continuo del log di backup. In caso di errori di connessione o permessi, il sistema intercetta l’evento, lo inserisce in una coda e invia notifiche email al cliente tramite API. Il worker gestisce la coda, garantendo la consegna delle notifiche anche in caso di errori temporanei.
📂 **Script:** [Warn_Client_2.sh](Warn_Client_2.sh)

## 3. Manutenzione Log
Gestione automatica dei file di log: compressione e archiviazione. Mantiene solo gli ultimi archivi per risparmiare spazio, con estrazione rapida dei log compressi. La pulizia è selettiva per evitare la perdita di dati rilevanti.
📂 **Script:** [Manutenzione_Log_3.sh](Manutenzione_Log_3.sh)

## 4. Controllo Quote e Prevenzione Abusi
Monitoraggio in tempo reale delle dimensioni dei trasferimenti. Se un processo supera la quota configurata, viene terminato automaticamente. Il sistema verifica che il PID sia attivo prima di eseguire il kill, garantendo la protezione dello storage.
📂 **Script:** [Quota_Killer_4.sh](Quota_Killer_4.sh)

## 5. Organizzazione Multi-Tenant (Log Splitting)
Demultiplexing dei log: estrazione delle voci relative a un singolo cliente, con filtri temporali opzionali. Genera file di log dedicati per ogni ID, semplificando troubleshooting e audit.
📂 **Script:** [split_logs_by_id_5.sh](split_logs_by_id_5.sh)

## 6. Igiene dello Storage (Cleanup)
Esecuzione periodica di garbage collection. Rimozione di file temporanei, parziali, di coda e offset. Analizza i log per individuare backup obsoleti e directory vuote, ruota e comprime i log, verifica errori ricorrenti e integrità dello storage.
📂 **Script:** [clean_up_6.sh](clean_up_6.sh)

## 7. Compliance GDPR (Force Full Backup)
Verifica automatica che ogni cliente abbia almeno un backup completo valido negli ultimi 7 giorni. In caso di mancanza, invia una notifica di alert. Garantisce la conformità alle strategie di Disaster Recovery e GDPR.
📂 **Script:** [backup_warn_7.sh](backup_warn_7.sh)

## 8. Sicurezza Accessi (Whitelist Enforcement)
Analisi del log di audit e verifica dello stato di ogni server tramite API. Blocca con iptables gli IP dei client non attivi (non paganti). Gestisce la whitelist e previene accessi non autorizzati.
📂 **Script:** [block_inactive_8.sh](block_inactive_8.sh)

## 9. Gestione Insoluti e Recupero Crediti
Integrazione con lo stato dei pagamenti. Invio automatico di solleciti email in caso di morosità, tracciamento dello stato di inattività, cancellazione sicura dei dati dopo un periodo definito di insolvenza. Tutto il processo è loggato e tracciato.
📂 **Script:** [payment_enforcer_9.sh](payment_enforcer_9.sh)

## 10. Audit Totale e Integrità (Full Verification)
Verifica fisica di tutti i file di backup contrassegnati come SUCCESS nel log. Controlla esistenza, leggibilità e dimensione effettiva dei file. In caso di errori, invia una email di riepilogo per ogni server con problemi rilevati.
📂 **Script:** [full_verification_10.sh](full_verification_10.sh)

