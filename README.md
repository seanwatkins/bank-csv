# bank-csv-to-influx

Watches a directory for **Canadian bank CSV exports**, parses them, and writes
transactions to **InfluxDB** for Grafana spending dashboards.  Includes a
separate tool (`recategorize.lisp`) to re-apply updated category rules to
existing data without re-importing the original files.

Written by Claude (https://claude.ai) with Sean Watkins.

---

## What it does

1. Polls an inbox directory every 5 seconds for `*.csv` files.
2. Auto-detects the bank format and parses transactions.
3. Checks InfluxDB for duplicates — skips rows already imported.
4. Writes new transactions to InfluxDB as `bank_transaction` measurements,
   tagged by `account` and `category`.
5. Moves the file to `imported/` (success) or `failed/` (parse / write error).

---

## Supported CSV formats

| Bank | Format |
|---|---|
| TD Bank | Headerless: date, description, debit, credit, balance |
| Mint export | Header-based with `Transaction Type`, `Category`, `Account Name` |
| Generic | Header-based: date, description, amount (or separate debit/credit), optional balance |
| RBC, Scotiabank, CIBC, BMO | Detected via the generic header-based parser |

---

## Requirements

- **SBCL** (Steel Bank Common Lisp)
- **Quicklisp** with:
  - `dexador` – HTTP client (InfluxDB writes and queries)
  - `local-time` – date/time parsing and UTC conversion
  - `cl-ppcre` – regex for CSV parsing and merchant categorisation
  - `uiop` – portable filesystem utilities
- A running **InfluxDB v2** instance

---

## Directory layout

```
/tmp/bank-csv/        (default root, override via env vars)
  inbox/              drop CSV files here
  imported/           successfully imported files land here (timestamped)
  failed/             files that could not be parsed or written
```

The inbox also contains the supporting scripts:

| File | Purpose |
|---|---|
| `bank-csv-to-influx.lisp` | Main importer — watches inbox and writes to InfluxDB |
| `recategorize.lisp` | Re-applies updated category rules to all existing InfluxDB records |
| `bank-categories.txt` | Merchant-to-category mapping rules (one rule per line) |
| `run` | Shell wrapper to launch the importer |
| `run-q` | Shell wrapper for a quiet / background run |
| `locate-uncategorized` | Helper to find transactions still tagged `other` |
| `recategorize` | Shell wrapper for `recategorize.lisp` |
| `debug-program` | SBCL debug launcher |
| `h.lisp` | Shared helper utilities |

---

## Configuration

All paths and InfluxDB connection details are set via environment variables
(preferred) or by editing the `defparameter` forms near the top of the source.

| Variable | Default | Description |
|---|---|---|
| `CSV_WATCH_DIR` | `/tmp/bank-csv/inbox` | Directory to watch for CSV files |
| `CSV_IMPORTED_DIR` | `/tmp/bank-csv/imported` | Destination for successfully imported files |
| `CSV_FAILED_DIR` | `/tmp/bank-csv/failed` | Destination for files that failed to import |
| `INFLUX_URL` | `http://localhost:8086` | InfluxDB base URL |
| `INFLUX_ORG` | `my-org` | InfluxDB organisation |
| `INFLUX_BUCKET_BANK` | `banking` | InfluxDB bucket for bank transactions |
| `INFLUX_TOKEN` | *(required)* | InfluxDB v2 API token |
| `CATEGORIES_FILE` | `bank-categories.txt` in cwd | Path to the category rules file |

---

## Usage

### Import transactions

Drop a CSV export from your bank into the inbox directory, then run:

```bash
export INFLUX_TOKEN=your_token
sbcl --load bank-csv-to-influx.lisp
```

Or use the included `run` wrapper. The importer loops continuously; press
`Ctrl-C` to stop.

### Re-apply category rules

After editing `bank-categories.txt`, update all existing InfluxDB records:

```bash
sbcl --load recategorize.lisp
```

This fetches every `bank_transaction` record, re-categorises each description
against the current rules, then deletes and rewrites the entire dataset.
You will be prompted to type `YES` before any data is modified.

---

## Category rules (`bank-categories.txt`)

Rules are loaded from `bank-categories.txt` (or the path in `CATEGORIES_FILE`).

```
# Format:  category:regex
# First matching rule wins — put specific rules before general ones.
# Lines starting with # and blank lines are ignored.
# Patterns are automatically made case-insensitive.

fuel:petro.?can|shell|esso
groceries:safeway|sobeys|superstore
restaurants:tim horton|starbucks|doordash
other:.
```

The built-in file covers common Canadian merchants across categories including
`fuel`, `groceries`, `restaurants`, `utilities`, `insurance`, `medical`,
`entertainment`, `travel`, `automotive`, `transport`, `fitness`, `clothing`,
`shopping`, `home_improvement`, `personal_care`, `financial`, and `other`.

---

## InfluxDB data model

**Measurement:** `bank_transaction`

| Tag | Description |
|---|---|
| `account` | Derived from the CSV filename (without extension) |
| `category` | Merchant category matched from `bank-categories.txt` |

| Field | Description |
|---|---|
| `amount` | Transaction amount (negative = debit, positive = credit) |
| `description` | Original merchant description string |
| `balance` | Running balance, if present in the CSV |

Timestamps are stored in nanoseconds at day precision (midnight UTC of the
transaction date).

---

## Mint export note

When importing a Mint export, only rows matching the account name
`TD AEROPLAN VISA INFINITE` are imported.  Mint category labels are mapped to
the local category scheme via an internal mapping table in `recategorize.lisp`.
Edit the `*mint-category-map*` parameter to adjust this mapping.
