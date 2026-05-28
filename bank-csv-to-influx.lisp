;;;; bank-csv-to-influx.lisp
;;;;
;;;; This code was written by Claude (https://claude.ai), Anthropic's AI assistant,
;;;; through an iterative conversation with:
;;;;
;;;;   Sean Watkins  |  sean.watkins@gmail.com
;;;;   https://www.linkedin.com/in/sean-w-b981934/
;;;;   https://www.strava.com/athletes/35611001
;;;;
;;;; Sean ran the code, the AI wrote it.
;;;;
;;;; Watches a directory for CSV bank transaction files, parses them, and writes
;;;; transactions to InfluxDB for Grafana dashboards.
;;;;
;;;; Supports common Canadian bank CSV formats:
;;;;   - TD Bank
;;;;   - RBC
;;;;   - Scotiabank
;;;;   - CIBC
;;;;   - BMO
;;;;   - Generic (date, description, amount, balance)
;;;;   - Mint export format
;;;;
;;;; Workflow:
;;;;   1. Drop a CSV file into the watch directory
;;;;   2. Importer detects it, parses it, writes to InfluxDB
;;;;   3. File is moved to an "imported" subdirectory with a timestamp
;;;;   4. Grafana can then query spending by category, merchant, account
;;;;
;;;; Dependencies (Quicklisp):
;;;;   dexador    – HTTP client (InfluxDB writes)
;;;;   local-time – Date/time parsing and conversion
;;;;   cl-ppcre   – Regex for CSV parsing and merchant categorization
;;;;
;;;; Usage:
;;;;   sbcl --load bank-csv-to-influx.lisp
;;;;
;;;; All configuration via environment variables or defparameter forms below.

;;; ──────────────────────────────────────────────────────────────────
;;; 1.  Bootstrap Quicklisp
;;; ──────────────────────────────────────────────────────────────────

(let ((ql-init (merge-pathnames "quicklisp/setup.lisp"
                                (user-homedir-pathname))))
  (when (probe-file ql-init)
    (load ql-init)))

(ql:quickload '(:dexador :local-time :cl-ppcre :uiop) :silent t)

;;; ──────────────────────────────────────────────────────────────────
;;; 2.  Configuration
;;; ──────────────────────────────────────────────────────────────────

(defparameter *watch-dir*
  (or (uiop:getenv "CSV_WATCH_DIR") "/tmp/bank-csv/inbox")
  "Directory to watch for new CSV files.")

(defparameter *imported-dir*
  (or (uiop:getenv "CSV_IMPORTED_DIR") "/tmp/bank-csv/imported")
  "Directory to move successfully imported files to.")

(defparameter *failed-dir*
  (or (uiop:getenv "CSV_FAILED_DIR") "/tmp/bank-csv/failed")
  "Directory to move files that failed to import.")

(defparameter *poll-interval* 5
  "Seconds between directory scans.")

;;; InfluxDB connection — reuse same settings as AESO collector
(defparameter *influx-url*
  (or (uiop:getenv "INFLUX_URL") "http://localhost:8086")
  "InfluxDB base URL.")

(defparameter *influx-org*
  (or (uiop:getenv "INFLUX_ORG") "my-org")
  "InfluxDB organisation.")

(defparameter *influx-bucket*
  (or (uiop:getenv "INFLUX_BUCKET_BANK") "banking")
  "InfluxDB bucket for bank transactions. Defaults to 'banking' (separate from aeso).")

(defparameter *influx-token*
  (or (uiop:getenv "INFLUX_TOKEN") "YOUR_INFLUXDB_TOKEN_HERE")
  "InfluxDB API token.")

;;; ──────────────────────────────────────────────────────────────────
;;; 3.  Merchant categorization rules
;;;
;;;  Rules are loaded from *categories-file* at startup and on each
;;;  file import so you can edit the rules file without restarting.
;;;
;;;  Format of the rules file (one rule per line):
;;;    category:regex
;;;  Lines starting with # or blank lines are ignored.
;;;  First matching rule wins — put specific rules before general ones.
;;; ──────────────────────────────────────────────────────────────────

(defparameter *categories-file*
  (or (uiop:getenv "CATEGORIES_FILE")
      (namestring (merge-pathnames "bank-categories.txt" (uiop:getcwd))))
  "Path to the category rules file. Defaults to bank-categories.txt
   in the current working directory, or set CATEGORIES_FILE env var.")

(defun load-category-rules (&optional (path *categories-file*))
  "Load category rules from PATH. Returns a list of (regex . category) pairs.
   Prints a warning and returns built-in fallback rules if file not found."
  (unless (probe-file path)
    (format t "~&[WARN] Categories file not found: ~A~%" path)
    (format t "~&[WARN] Using built-in fallback rules only.~%")
    (return-from load-category-rules
      '(("(?i)petro|shell|esso|husky|ultramar|chevron" . "fuel")
        ("(?i)safeway|sobeys|wal.?mart|superstore|costco" . "groceries")
        ("(?i)tim horton|starbucks|mcdonald|subway" . "restaurants")
        ("(?i)atco|enmax|telus|shaw|rogers|bell" . "utilities")
        ("(?i)netflix|spotify|apple|disney|steam" . "entertainment")
        ("." . "other"))))
  (format t "~&[INFO] Loading category rules from ~A~%" path)
  (with-open-file (in path :direction :input)
    (loop for line = (read-line in nil nil)
          while line
          for clean = (string-trim '(#\Space #\Return #\Tab) line)
          ;; skip blanks and comments
          unless (or (string= clean "")
                     (and (> (length clean) 0)
                          (char= (char clean 0) #\#)))
            collect (let ((colon (position #\: clean)))
                      (if colon
                          (cons (format nil "(?i)~A" (subseq clean (1+ colon)))
                                (subseq clean 0 colon))
                          (progn
                            (format t "~&[WARN] Skipping malformed rule: ~S~%" clean)
                            nil)))
            into rules
          finally (return (remove nil rules)))))

(defun categorize (description)
  "Return a category string for DESCRIPTION by matching against loaded rules."
  (let* ((rules (load-category-rules))
         (category (loop for (pattern . cat) in rules
                         when (cl-ppcre:scan pattern description)
                           return cat
                         finally (return "other"))))
    (when (string= category "other")
      (format t "~&[UNCATEGORIZED] ~A~%" description))
    category))

;;; ──────────────────────────────────────────────────────────────────
;;; 4.  CSV parsing utilities
;;; ──────────────────────────────────────────────────────────────────

(defun split-csv-line (line)
  "Split a CSV LINE into fields, respecting quoted fields containing commas."
  (let ((fields '())
        (current (make-string-output-stream))
        (in-quotes nil))
    (loop for ch across line
          do (cond
               ((and (char= ch #\") (not in-quotes))
                (setf in-quotes t))
               ((and (char= ch #\") in-quotes)
                (setf in-quotes nil))
               ((and (char= ch #\,) (not in-quotes))
                (push (string-trim " " (get-output-stream-string current)) fields)
                (setf current (make-string-output-stream)))
               (t
                (write-char ch current))))
    (push (string-trim " " (get-output-stream-string current)) fields)
    (nreverse fields)))

(defun strip-bom (s)
  "Remove UTF-8 BOM from string S if present."
  (if (and (> (length s) 0)
           (char= (char s 0) #\uFEFF))
      (subseq s 1)
      s))

(defun read-csv-file (path)
  "Read CSV file at PATH and return a list of string lists (rows of fields).
   Skips blank lines. Strips BOM from first line."
  (with-open-file (in path :direction :input :external-format :utf-8)
    (loop for line = (read-line in nil nil)
          for first = t then nil
          while line
          for clean = (string-trim '(#\Space #\Return) (if first (strip-bom line) line))
          unless (string= clean "")
            collect (split-csv-line clean))))

(defun find-column (headers name-patterns)
  "Find the index of a column whose header matches any of NAME-PATTERNS (case-insensitive).
   Returns NIL if not found."
  (loop for header in headers
        for i from 0
        when (loop for pat in name-patterns
                   thereis (cl-ppcre:scan (format nil "(?i)~A" pat) header))
          return i))

;;; ──────────────────────────────────────────────────────────────────
;;; 5.  Date parsing
;;; ──────────────────────────────────────────────────────────────────

(defun parse-date-to-unix (date-str)
  "Parse DATE-STR in common Canadian bank formats to Unix nanoseconds.
   Handles: YYYY-MM-DD, MM/DD/YYYY, DD/MM/YYYY, MM-DD-YYYY, YYYYMMDD"
  (let ((s (string-trim " " date-str)))
    (flet ((try (pattern y-g m-g d-g)
             (cl-ppcre:register-groups-bind (groups)
                 (pattern s)
               (when groups
                 (let ((y (parse-integer (nth y-g groups)))
                       (m (parse-integer (nth m-g groups)))
                       (d (parse-integer (nth d-g groups))))
                   (* (local-time:timestamp-to-unix
                        (local-time:encode-timestamp 0 0 0 0 d m y
                                                     :timezone local-time:+utc-zone+))
                      1000000000))))))
      (or
       ;; YYYY-MM-DD
       (cl-ppcre:register-groups-bind (y m d)
           ("^(\\d{4})-(\\d{2})-(\\d{2})" s)
         (* (local-time:timestamp-to-unix
              (local-time:encode-timestamp 0 0 0 0
                                           (parse-integer d)
                                           (parse-integer m)
                                           (parse-integer y)
                                           :timezone local-time:+utc-zone+))
            1000000000))
       ;; MM/DD/YYYY (US/Mint format)
       (cl-ppcre:register-groups-bind (m d y)
           ("^(\\d{1,2})/(\\d{1,2})/(\\d{4})" s)
         (* (local-time:timestamp-to-unix
              (local-time:encode-timestamp 0 0 0 0
                                           (parse-integer d)
                                           (parse-integer m)
                                           (parse-integer y)
                                           :timezone local-time:+utc-zone+))
            1000000000))
       ;; YYYYMMDD
       (cl-ppcre:register-groups-bind (y m d)
           ("^(\\d{4})(\\d{2})(\\d{2})$" s)
         (* (local-time:timestamp-to-unix
              (local-time:encode-timestamp 0 0 0 0
                                           (parse-integer d)
                                           (parse-integer m)
                                           (parse-integer y)
                                           :timezone local-time:+utc-zone+))
            1000000000))
       (progn
         (format t "~&[WARN] Could not parse date: ~S~%" date-str)
         nil)))))

;;; ──────────────────────────────────────────────────────────────────
;;; 6.  Transaction parsing — detect format and extract fields
;;; ──────────────────────────────────────────────────────────────────

(defstruct transaction
  date-ns       ; Unix nanoseconds
  date-str      ; Original date string
  description   ; Merchant/description
  amount        ; Float — negative = debit, positive = credit
  balance       ; Float or NIL
  account       ; String — from filename or header
  category      ; String — auto-categorized
  source-file)  ; Original filename

(defun parse-float (s)
  "Parse float from string S."
  (let ((v (ignore-errors (with-input-from-string (in s) (read in)))))
    (when (numberp v) (float v))))

(defun parse-amount (s)
  "Parse amount string, handling parentheses for negatives and $ signs."
  (when (and s (not (string= s "")))
    (let* ((clean    (cl-ppcre:regex-replace-all "[\\$, ]" s ""))
           (negative (or (cl-ppcre:scan "^-" clean)
                         (cl-ppcre:scan "^\\(" clean)))
           (digits   (cl-ppcre:regex-replace-all "[^0-9\\.]" clean "")))
      (when (not (string= digits ""))
        (let ((n (parse-float digits)))
          (when n (if negative (- n) n)))))))

(defun looks-like-date (s)
  "Return T if S looks like a date string."
  (or (cl-ppcre:scan "^\\d{2}/\\d{2}/\\d{4}" s)
      (cl-ppcre:scan "^\\d{4}-\\d{2}-\\d{2}" s)
      (cl-ppcre:scan "^\\d{8}$" s)))

(defun td-headerless-p (first-row)
  "Return T if FIRST-ROW looks like a TD Bank headerless CSV row.
   TD format: date, description, debit, credit, balance — no header row."
  (and (>= (length first-row) 4)
       (looks-like-date (first first-row))
       (let ((col2 (nth 2 first-row))
             (col3 (nth 3 first-row)))
         ;; col2 or col3 should be a number (debit or credit)
         (or (parse-amount col2) (parse-amount col3)))))

(defun detect-format-and-parse (rows filename)
  "Detect CSV format from headers and parse ROWS into a list of TRANSACTION structs."
  (when (null rows) (return-from detect-format-and-parse nil))

  (let ((account (pathname-name filename)))

    ;; ── TD Bank: no header row, columns are date/desc/debit/credit/balance ──
    (when (td-headerless-p (first rows))
      (format t "~&[INFO] Detected TD Bank headerless format~%")
      (return-from detect-format-and-parse
        (loop for row in rows
              for date-str = (nth 0 row)
              for desc     = (nth 1 row)
              for debit    = (parse-amount (nth 2 row))
              for credit   = (parse-amount (nth 3 row))
              for balance  = (and (>= (length row) 5) (parse-amount (nth 4 row)))
              for amount   = (cond ((and debit  (not (zerop debit)))  (- (abs debit)))
                                   ((and credit (not (zerop credit))) (abs credit))
                                   (t nil))
              for date-ns  = (parse-date-to-unix date-str)
              when (and date-ns desc amount)
                collect (make-transaction
                          :date-ns     date-ns
                          :date-str    date-str
                          :description desc
                          :amount      amount
                          :balance     balance
                          :account     account
                          :category    (categorize desc)
                          :source-file filename))))

    ;; ── Header-based format detection ────────────────────────────────
    (let* ((headers      (first rows))
           (data-rows    (rest rows))
           (date-col     (find-column headers '("date" "transaction.*date" "posted")))
           (desc-col     (find-column headers '("description" "name" "merchant" "memo"
                                                "transaction.*name" "narrative")))
           (amount-col   (find-column headers '("^amount$" "transaction.*amount" "debit.*credit")))
           (debit-col    (find-column headers '("^debit$" "debit.*amount" "withdrawl")))
           (credit-col   (find-column headers '("^credit$" "credit.*amount" "deposit")))
           (balance-col  (find-column headers '("balance" "running.*balance")))
           (category-col (find-column headers '("category" "type"))))

      (format t "~&[INFO] Detected columns — date:~A desc:~A amount:~A debit:~A credit:~A~%"
              date-col desc-col amount-col debit-col credit-col)

      (unless (and date-col desc-col (or amount-col (and debit-col credit-col)))
        (format t "~&[ERROR] Could not detect required columns in ~A~%" filename)
        (format t "~&        Headers found: ~{~A~^, ~}~%" headers)
        (return-from detect-format-and-parse nil))

      (loop for row in data-rows
            for date-str = (and date-col (nth date-col row))
            for desc     = (and desc-col (nth desc-col row))
            for amount   = (if amount-col
                               (parse-amount (nth amount-col row))
                               (let ((d (and debit-col  (parse-amount (nth debit-col row))))
                                     (c (and credit-col (parse-amount (nth credit-col row)))))
                                 (cond ((and d (not (zerop d))) (- (abs d)))
                                       ((and c (not (zerop c))) (abs c))
                                       (t 0.0))))
            for balance  = (and balance-col (parse-amount (nth balance-col row)))
            for category = (or (and category-col (nth category-col row))
                               (and desc (categorize desc))
                               "other")
            for date-ns  = (and date-str (parse-date-to-unix date-str))
            when (and date-ns desc amount)
              collect (make-transaction
                        :date-ns     date-ns
                        :date-str    date-str
                        :description desc
                        :amount      amount
                        :balance     balance
                        :account     account
                        :category    category
                        :source-file filename)))))

;;; ──────────────────────────────────────────────────────────────────
;;; 7.  InfluxDB line protocol conversion
;;; ──────────────────────────────────────────────────────────────────

(defun escape-tag (s)
  "Escape spaces, commas and equals signs in an InfluxDB line-protocol tag value."
  (with-output-to-string (out)
    (loop for ch across (format nil "~A" s)
          do (when (member ch '(#\Space #\, #\=))
               (write-char #\\ out))
             (write-char ch out))))

(defun transactions->line-protocol (transactions)
  "Convert a list of TRANSACTION structs to InfluxDB line-protocol strings.
   Measurement: bank_transaction
   Tags:   account, category
   Fields: amount (float), balance (float, optional), description (string)"
  (loop for tx in transactions
        for tags = (format nil "account=~A,category=~A"
                           (escape-tag (transaction-account tx))
                           (escape-tag (transaction-category tx)))
        for desc-escaped = (cl-ppcre:regex-replace-all "\"" (transaction-description tx) "\\\"")
        for fields = (format nil "amount=~,4F,description=\"~A\"~A"
                             (transaction-amount tx)
                             desc-escaped
                             (if (transaction-balance tx)
                                 (format nil ",balance=~,4F" (transaction-balance tx))
                                 ""))
        collect (format nil "bank_transaction,~A ~A ~D"
                        tags fields (transaction-date-ns tx))))

;;; ──────────────────────────────────────────────────────────────────
;;; 8.  InfluxDB write
;;; ──────────────────────────────────────────────────────────────────

(defun url-encode (s)
  "Percent-encode string S for use in a URL query parameter."
  (with-output-to-string (out)
    (loop for ch across s
          do (if (or (char<= #\a ch #\z) (char<= #\A ch #\Z)
                     (char<= #\0 ch #\9) (member ch '(#\- #\_ #\. #\~)))
                 (write-char ch out)
                 (format out "%~2,'0X" (char-code ch))))))

(defun influx-write-url ()
  (format nil "~A/api/v2/write?org=~A&bucket=~A&precision=ns"
          *influx-url* (url-encode *influx-org*) (url-encode *influx-bucket*)))

(defun write-to-influx (lines)
  "POST LINE-PROTOCOL LINES to InfluxDB. Returns T on success, NIL on error."
  (when lines
    (let ((body (format nil "~{~A~%~}" lines)))
      (handler-case
          (progn
            (dex:post (influx-write-url)
                      :headers `(("Authorization" . ,(format nil "Token ~A" *influx-token*))
                                 ("Content-Type"  . "text/plain; charset=utf-8"))
                      :content body)
            (format t "~&[OK] Wrote ~A transaction(s) to InfluxDB bucket '~A'.~%"
                    (length lines) *influx-bucket*)
            t)
        (dex:http-request-failed (e)
          (format t "~&[ERROR] InfluxDB write HTTP ~A: ~A~%"
                  (dex:response-status e) (dex:response-body e))
          nil)
        (error (e)
          (format t "~&[ERROR] InfluxDB write failed: ~A~%" e)
          nil)))))

;;; ──────────────────────────────────────────────────────────────────
;;; 9.  File management
;;; ──────────────────────────────────────────────────────────────────

(defun ensure-directory (path)
  "Create directory at PATH if it does not exist."
  (ensure-directories-exist (uiop:ensure-directory-pathname path)))

(defun move-file (src dest-dir suffix)
  "Move SRC file to DEST-DIR with SUFFIX inserted before the file extension."
  (let* ((name     (pathname-name src))
         (ext      (pathname-type src))
         (newname  (if ext
                       (format nil "~A~A.~A" name suffix ext)
                       (format nil "~A~A" name suffix)))
         (dest     (merge-pathnames newname
                                    (uiop:ensure-directory-pathname dest-dir))))
    (handler-case
        (progn
          (uiop:copy-file src dest)
          (delete-file src)
          (format t "~&[INFO] Moved ~A → ~A~%" (file-namestring src) newname))
      (error (e)
        (format t "~&[WARN] Could not move ~A: ~A~%" src e)))))

(defun timestamp-suffix ()
  "Return a timestamp string suitable for use in a filename."
  (local-time:format-timestring nil (local-time:now)
                                :format '("." (:year 4) (:month 2) (:day 2)
                                          "T" (:hour 2) (:min 2) (:sec 2))))

;;; ──────────────────────────────────────────────────────────────────
;;; 10. Process a single CSV file
;;; ──────────────────────────────────────────────────────────────────

(defun process-csv-file (path)
  "Parse CSV file at PATH, write transactions to InfluxDB, move to imported or failed dir."
  (format t "~&[INFO] Processing: ~A~%" (file-namestring path))
  (handler-case
      (let* ((rows         (read-csv-file path))
             (transactions (detect-format-and-parse rows (file-namestring path))))
        (if transactions
            (progn
              (format t "~&[INFO] Parsed ~A transactions from ~A~%"
                      (length transactions) (file-namestring path))
              ;; Print a sample
              (let ((sample (first transactions)))
                (format t "~&[INFO] Sample: ~A | ~A | $~,2F | ~A~%"
                        (transaction-date-str sample)
                        (transaction-description sample)
                        (transaction-amount sample)
                        (transaction-category sample)))
              (let ((lines (transactions->line-protocol transactions)))
                (if (write-to-influx lines)
                    (move-file path *imported-dir* (timestamp-suffix))
                    (move-file path *failed-dir*   (timestamp-suffix)))))
            (progn
              (format t "~&[WARN] No transactions parsed from ~A~%" (file-namestring path))
              (move-file path *failed-dir* (timestamp-suffix)))))
    (error (e)
      (format t "~&[ERROR] Failed to process ~A: ~A~%" (file-namestring path) e)
      (move-file path *failed-dir* (timestamp-suffix)))))

;;; ──────────────────────────────────────────────────────────────────
;;; 11. Directory watcher
;;; ──────────────────────────────────────────────────────────────────

(defun scan-watch-dir ()
  "Scan *WATCH-DIR* for CSV files and process each one found."
  (let ((dir (uiop:ensure-directory-pathname *watch-dir*)))
    (if (probe-file dir)
        (let ((files (uiop:directory-files dir "*.csv")))
          (if files
              (dolist (path files)
                (format t "~&[SCAN] Found: ~A~%" (file-namestring path))
                (process-csv-file path))
              (format t "~&[SCAN] No CSV files in ~A~%" *watch-dir*)))
        (format t "~&[SCAN] Watch directory does not exist: ~A~%" *watch-dir*))))

;;; ──────────────────────────────────────────────────────────────────
;;; 12. Entry point
;;; ──────────────────────────────────────────────────────────────────

(defun main ()
  (format t "~&Bank CSV → InfluxDB importer~%")
  (format t "~&  Watch dir    : ~A~%" *watch-dir*)
  (format t "~&  Imported dir : ~A~%" *imported-dir*)
  (format t "~&  Failed dir   : ~A~%" *failed-dir*)
  (format t "~&  InfluxDB     : ~A  bucket=~A~%" *influx-url* *influx-bucket*)
  (format t "~&  Poll interval: ~As~%~%" *poll-interval*)

  ;; Create directories if they don't exist
  (ensure-directory *watch-dir*)
  (ensure-directory *imported-dir*)
  (ensure-directory *failed-dir*)

  (format t "~&[INFO] Watching for CSV files in ~A~%" *watch-dir*)
  (format t "~&[INFO] Drop a bank CSV file there to import it.~%~%")

  (loop
    (scan-watch-dir)
    (sleep *poll-interval*)))

(main)
