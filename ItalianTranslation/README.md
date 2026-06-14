# Traduzione italiana di Hunter's Moon

Questa cartella contiene sia il lavoro di traduzione sia il pacchetto pronto da reinstallare.

## Struttura

- `source/English.json`: estrazione originale del testo inglese.
- `work/Italian.json`: base di lavoro.
- `work/Italian_translated.json`: traduzione aggiornata.
- `release/`: file da copiare nel gioco.
- `ItalianTranslator.ps1`: interfaccia unica con analisi, sincronizzazione, generazione, installazione, disinstallazione e validazione.
- `ItalianTranslator.cmd`: avvio rapido della GUI senza dover scrivere il comando PowerShell.
- `backup/`: backup automatici creati dall'installer.

Il tool non richiede Python: l'estrazione da `resources.assets` usa componenti inclusi in PowerShell/.NET.

Le due tabelle originali riutilizzano alcune chiavi con significati diversi. Il tool le conserva come `main::chiave` per menu, dialoghi e titoli delle carte, e `custom::chiave` per descrizioni e keyword. In questo modo una descrizione non può più sovrascrivere il titolo della carta; nomi e percorsi dei file della mod restano invariati.

## Cosa fa la mod

La versione italiana sostituisce la lingua inglese nel menu con l'italiano e carica la traduzione da `StreamingAssets\Locales\Italian_translated.json`.

In pratica:

- nel menu vedrai `Italiano` al posto di `English`;
- se selezioni quella voce, il gioco userà i testi italiani;
- le cutscene, i tooltip e gli altri testi che il gioco carica dalle tabelle `Translations - All` e `Custom Translations - All` vengono inclusi nel file italiano;
- i riferimenti delle carte come `<keyword_block>` vengono risolti dalla DLL prima della visualizzazione, evitando che i tag interni compaiano nel gioco;
- il pacchetto resta riutilizzabile anche dopo una reinstallazione del gioco.

## Aggiornamenti del gioco

Se il gioco viene aggiornato, apri `ItalianTranslator.ps1` e usa il pulsante `Generate mod`:

```powershell
.\ItalianTranslator.cmd
```

La GUI confronta `Hunters Moon_Data\resources.assets` con la base in `source\English.json`, recupera anche i campi multilinea, aggiorna i file in `work\` e riscrive la traduzione pronta da installare. Le vecchie traduzioni restano salvate e vengono tradotti solo i testi nuovi, modificati, ancora in inglese oppure diventati incompatibili con i token del gioco.

La traduzione avviene in batch dinamici. Il tool:

- usa la key come contesto, ma associa il risultato tramite un indice verificato;
- ritenta e suddivide automaticamente un batch se Ollama restituisce JSON incompleto;
- salva un checkpoint dopo ogni batch;
- marca come pendenti i testi nuovi o modificati prima di tradurli, così una Sync interrotta può riprendere correttamente;
- conserva gli ultimi cinque backup in `backup/history/`;
- mantiene Ollama caricato tra i batch per ridurre i tempi di attesa.

## Uso rapido

Apri la GUI e usa i pulsanti:

- `Analyze`: mostra quante chiavi ci sono e quante mancano.
- `Generate mod`: estrae, confronta, traduce e rigenera la release.
- `Review all`: crea un backup e ritraduce tutte le voci dalla sorgente inglese corrente; serve per correggere traduzioni vecchie, letterali o non più coerenti con il gioco.
- `Install`: copia la mod nel gioco.
- `Uninstall`: ripristina i file originali usando i backup.
- `Validate`: controlla chiavi e token protetti.
- `Cancel`: interrompe in modo pulito l'operazione in corso.

## Nota

I nomi propri, i termini di gioco già consolidati e i token tra parentesi quadre o tag HTML devono restare invariati.
