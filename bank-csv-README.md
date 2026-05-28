# Bank CSV → InfluxDB Transaction Importer

> **This code was written by [Claude](https://claude.ai) (Anthropic), an AI assistant,
> through an iterative conversation with a human operator — the human ran the code,
> the AI wrote it.**

A Common Lisp program that watches a directory for bank CSV export files, parses
transactions, auto-categorizes merchants, and writes everything to InfluxDB for
Grafana spending dashboards.

---

## Files

| File | Purpose |
|------|---------|
| `bank-csv-to-influx.lisp` | Main importer — watches inbox, parses CSVs, writes to InfluxDB |
| `recategorize.lisp` | Re-categorizes existing InfluxDB data when rules change — no re-import needed |
| `bank-categories.txt` | Merchant category rules — edit this to fix categorization |

---

## Features

- Watches a directory and imports CSV files automatically within 5 seconds of drop
- Auto-detects TD Bank headerless format and standard header-based formats
- Parses dates in any common format — `YYYY-MM-DD`, `MM/DD/YYYY`, `YYYYMMDD`
- Category rules loaded from external `bank-categories.txt` — edit without restarting
- Re-categorize existing data with `recategorize.lisp` — no CSV re-import needed
- Moves imported files to `imported/` with timestamp inserted before extension
- Failed files moved to `failed/` for inspection
- Prints `[UNCATEGORIZED]` for every transaction that falls through to `other`

---

## Prerequisites

| Tool | Notes |
|------|-------|
| [SBCL](https://www.sbcl.org/) | `sudo apt install sbcl` |
| [Quicklisp](https://www.quicklisp.org/) | Standard Lisp package manager |
| InfluxDB 2.x | Same instance as AESO collector |
| Grafana | Same instance as AESO collector |

### Quicklisp dependencies (auto-installed)

`dexador` `local-time` `cl-ppcre` `uiop`

---

## Quick Start

### 1. Create the watch directories

```bash
sudo mkdir -p /var/bank-csv/{inbox,imported,failed}
sudo chmod 777 /var/bank-csv/inbox
```

### 2. Create the InfluxDB bucket

In the InfluxDB UI at `http://localhost:8086`:

1. **Load Data → Buckets → Create Bucket**
2. Name it `banking`
3. Retention: `0` (keep forever)

### 3. Configure environment variables

```bash
export INFLUX_URL="http://localhost:8086"
export INFLUX_ORG="my-org"
export INFLUX_BUCKET_BANK="banking"
export INFLUX_TOKEN="your-influxdb-token"

# Optional overrides
export CSV_WATCH_DIR="/var/bank-csv/inbox"
export CSV_IMPORTED_DIR="/var/bank-csv/imported"
export CSV_FAILED_DIR="/var/bank-csv/failed"
export CATEGORIES_FILE="/path/to/bank-categories.txt"
```

### 4. Run

```bash
sbcl --load bank-csv-to-influx.lisp
```

### 5. Import a file

Name your CSV descriptively before dropping it in — the filename becomes the `account` tag:

```bash
cp ~/Downloads/accountactivity.csv /var/bank-csv/inbox/td-chequing.csv
```

The importer detects it within 5 seconds and prints a summary.

---

## Configuration

| Parameter | Env var | Default | Description |
|-----------|---------|---------|-------------|
| `*watch-dir*` | `CSV_WATCH_DIR` | `/tmp/bank-csv/inbox` | Directory to watch |
| `*imported-dir*` | `CSV_IMPORTED_DIR` | `/tmp/bank-csv/imported` | Successfully imported |
| `*failed-dir*` | `CSV_FAILED_DIR` | `/tmp/bank-csv/failed` | Failed imports |
| `*influx-url*` | `INFLUX_URL` | `http://localhost:8086` | InfluxDB URL |
| `*influx-org*` | `INFLUX_ORG` | `my-org` | InfluxDB organisation |
| `*influx-bucket*` | `INFLUX_BUCKET_BANK` | `banking` | InfluxDB bucket |
| `*influx-token*` | `INFLUX_TOKEN` | — | InfluxDB API token |
| `*categories-file*` | `CATEGORIES_FILE` | `bank-categories.txt` in cwd | Rules file path |
| `*poll-interval*` | — | `5` | Seconds between directory scans |

---

## Supported CSV Formats

| Bank | Date format | Notes |
|------|-------------|-------|
| TD Bank | `MM/DD/YYYY` | **No header row** — auto-detected |
| RBC | `YYYY-MM-DD` | Header row required |
| Scotiabank | `DD/MM/YYYY` | Header row required |
| CIBC | `YYYY-MM-DD` | Header row required |
| BMO | `YYYY-MM-DD` | Header row required |
| Mint export | `MM/DD/YYYY` | Uses Mint's existing Category column |
| Generic | auto-detected | Any CSV with date/description/amount columns |

**TD Bank note:** TD exports have no header row. The importer detects this by checking
if the first row's first column looks like a date. Columns are: `date, description, debit, credit, balance`.

**Naming tip:** Name your CSV before dropping it in the inbox — the filename (without
extension) becomes the `account` tag in Grafana:
```bash
cp export.csv inbox/td-chequing.csv      # account=td-chequing
cp export.csv inbox/td-visa.csv          # account=td-visa
```

---

## Category Rules — bank-categories.txt

Rules are loaded fresh on every file import — edit the file and drop a CSV without restarting.

**Format:** `category:regex` — one per line, `#` = comment, blank lines ignored.
Regex is automatically case-insensitive. First matching rule wins.

```
# Example rules
fuel:petro|shell|esso
groceries:safeway|sobeys|wal.?mart
restaurants:mcdonald|tim horton|starbucks
other:.
```

**To find uncategorized transactions:**
- Watch the terminal for `[UNCATEGORIZED] MERCHANT NAME` lines during import
- Or query InfluxDB: filter `r.category == "other"` and look at `description` field

**To fix categories without re-importing:**
```bash
# 1. Edit bank-categories.txt
# 2. Run recategorize.lisp
sbcl --load recategorize.lisp
# Type YES when prompted
```

---

## Categories

| Category | Example merchants |
|----------|------------------|
| `fuel` | Petro-Canada, Shell, Esso, Husky |
| `groceries` | Safeway, Sobeys, Walmart, Costco, Co-op |
| `restaurants` | McDonald's, Tim Hortons, DoorDash, SkipTheDishes, local restaurants |
| `utilities` | ATCO, ENMAX, TELUS, Shaw, Rogers, Bell |
| `insurance` | Intact, Cooperators, Wawanesa |
| `medical` | Shoppers, Rexall, dental, clinics, physio |
| `entertainment` | Netflix, Spotify, Apple, Steam, Globe & Mail |
| `cannabis` | Four20, 420 Premium Markets |
| `home_improvement` | Home Depot, RONA, Canadian Tire |
| `automotive` | Jiffy Lube, Fountain Tire, Kal Tire |
| `transport` | Uber, Calgary Transit, parking |
| `travel` | WestJet, Air Canada, hotels, Alamo, Airbnb |
| `clothing` | Winners, Sport Chek, Strides Running |
| `shopping` | Amazon, Best Buy, Chapters |
| `personal_care` | Distilled Beauty Bar, salons, spas |
| `financial` | Credit card payments, transfers, interest charges |
| `other` | Catch-all for unmatched transactions |

---

## Data Written to InfluxDB

### Measurement: `bank_transaction`

| Tag | Description |
|-----|-------------|
| `account` | From the CSV filename e.g. `td-chequing` |
| `category` | Auto-categorized merchant type |

| Field | Type | Description |
|-------|------|-------------|
| `amount` | float | **Negative = debit/spending, positive = credit/refund** |
| `balance` | float | Running balance (if in CSV) |
| `description` | string | Original merchant description from bank |

---

## Recategorize Existing Data

After updating `bank-categories.txt`, run `recategorize.lisp` to fix existing records
without re-importing CSVs:

```bash
sbcl --load recategorize.lisp
```

The script:
1. Fetches all transactions from InfluxDB
2. Re-runs every description through the current rules
3. Prints each transaction that will change category
4. Asks for `YES` confirmation before making changes
5. Deletes old records and rewrites with updated categories in batches of 500

---

## Grafana Queries

### Net monthly spending by category (stacked bar chart)

```flux
from(bucket: "banking")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "bank_transaction")
  |> filter(fn: (r) => r._field == "amount")
  |> filter(fn: (r) => r.category != "financial")
  |> map(fn: (r) => ({_time: r._time, _value: r._value * -1.0, _field: r.category}))
  |> group(columns: ["_field"])
  |> aggregateWindow(every: 1mo, fn: sum, createEmpty: false)
```
Visualization: **Bar chart**, Stacking: **Normal**

### Total spend by category for selected period (bar gauge)

```flux
from(bucket: "banking")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "bank_transaction")
  |> filter(fn: (r) => r._field == "amount")
  |> filter(fn: (r) => r._value < 0)
  |> filter(fn: (r) => r.category != "financial")
  |> map(fn: (r) => ({_time: r._time, _value: r._value * -1.0, _field: r.category}))
  |> group(columns: ["_field"])
  |> sum()
  |> map(fn: (r) => ({_value: r._value, _field: r._field}))
  |> group()
```
Visualization: **Bar gauge**, Color scheme: **Green-Yellow-Red**, Sort: Descending

### Fuel cost per month (for EV payback calculation)

```flux
from(bucket: "banking")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "bank_transaction")
  |> filter(fn: (r) => r._field == "amount")
  |> filter(fn: (r) => r._value < 0)
  |> filter(fn: (r) => r.category == "fuel")
  |> map(fn: (r) => ({r with _value: r._value * -1.0}))
  |> group()
  |> aggregateWindow(every: 1mo, fn: sum, createEmpty: false)
```

### Fuel cumulative total (add as Query B on same panel)

```flux
from(bucket: "banking")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "bank_transaction")
  |> filter(fn: (r) => r._field == "amount")
  |> filter(fn: (r) => r._value < 0)
  |> filter(fn: (r) => r.category == "fuel")
  |> map(fn: (r) => ({r with _value: r._value * -1.0}))
  |> group()
  |> aggregateWindow(every: 1mo, fn: sum, createEmpty: false)
  |> cumulativeSum()
```

### Biggest single transactions

```flux
from(bucket: "banking")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "bank_transaction")
  |> filter(fn: (r) => r._field == "amount")
  |> filter(fn: (r) => r._value < -100)
  |> sort(columns: ["_value"])
  |> limit(n: 20)
```

### Average monthly spend by category

```flux
from(bucket: "banking")
  |> range(start: -365d)
  |> filter(fn: (r) => r._measurement == "bank_transaction")
  |> filter(fn: (r) => r._field == "amount")
  |> filter(fn: (r) => r._value < 0)
  |> filter(fn: (r) => r.category != "financial")
  |> map(fn: (r) => ({_time: r._time, _value: r._value * -1.0, _field: r.category}))
  |> group(columns: ["_field"])
  |> aggregateWindow(every: 1mo, fn: sum, createEmpty: false)
  |> mean()
```

### All transactions — description pivot for debugging

```flux
from(bucket: "banking")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "bank_transaction")
  |> filter(fn: (r) => r._field == "amount")
  |> filter(fn: (r) => r.category == "other")
  |> keep(columns: ["_time", "_value", "description", "category"])
  |> sort(columns: ["_value"])
```

---

## Running as a System Service

```bash
sudo cp bank-csv-to-influx.lisp /opt/aeso/
sudo cp bank-categories.txt /opt/aeso/
sudo cp bank-csv-importer.service /etc/systemd/system/
sudo nano /etc/systemd/system/bank-csv-importer.service  # set credentials
sudo systemctl daemon-reload
sudo systemctl enable --now bank-csv-importer
sudo journalctl -u bank-csv-importer -f
```

---

## Troubleshooting

**File moves to `failed/`**
Check the log — it prints detected headers. If columns aren't found, your bank uses
non-standard header names. Add them to `find-column` calls in `detect-format-and-parse`.

**TD Bank files not detected**
The TD headerless detector checks if the first field looks like a date and columns 3/4
contain numbers. If your TD export has a different structure, check `td-headerless-p`.

**All transactions show as `other`**
Watch the terminal for `[UNCATEGORIZED]` lines. Add matching rules to `bank-categories.txt`.
Rules reload on every import — no restart needed.

**`recategorize.lisp` shows 0 transactions fetched**
The pivot query may be timing out on large datasets. Check InfluxDB is running and
the token has read access to the `banking` bucket.

**Duplicate transactions after re-import**
InfluxDB uses timestamp as part of the unique key. If the same transaction has the
same timestamp and tags it will overwrite, not duplicate. True duplicates only occur
if you import the same file twice with different filenames.

---

## Notes

- The `banking` bucket is separate from `aeso` — personal financial data isolated from grid monitoring
- Set retention to `0` (infinite) — transaction history is valuable for year-over-year comparisons
- Mint exported transactions include a `Category` column — the importer uses it directly
- `financial` category (credit card payments, transfers) should be excluded from spending charts
  since it represents money movement between accounts, not actual spending
- Credits (positive amounts) net against debits in the same category when using `sum()` without
  a negative filter — useful for seeing refunds offset against spending
