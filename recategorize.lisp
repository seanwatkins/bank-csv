;;;; recategorize.lisp
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
;;;; Re-categorizes existing bank_transaction records in InfluxDB by:
;;;;   1. Reading all transactions (amount + description + existing tags)
;;;;   2. Running each description through the current bank-categories.txt rules
;;;;   3. Deleting the old records via the InfluxDB delete API
;;;;   4. Writing new records with updated category tags
;;;;
;;;; Run this after updating bank-categories.txt to fix existing data without
;;;; needing to re-import original CSV files.
;;;;
;;;; Usage:
;;;;   sbcl --load recategorize.lisp
;;;;
;;;; Dependencies: same as bank-csv-to-influx.lisp (dexador, yason, local-time, cl-ppcre)

(let ((ql-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file ql-init) (load ql-init)))

(ql:quickload '(:dexador :yason :local-time :cl-ppcre :uiop) :silent t)

;;; ──────────────────────────────────────────────────────────────────
;;; Configuration — same env vars as bank-csv-to-influx.lisp
;;; ──────────────────────────────────────────────────────────────────

(defparameter *influx-url*   (or (uiop:getenv "INFLUX_URL")          "http://localhost:8086"))
(defparameter *influx-org*   (or (uiop:getenv "INFLUX_ORG")          "my-org"))
(defparameter *influx-bucket* (or (uiop:getenv "INFLUX_BUCKET_BANK") "banking"))
(defparameter *influx-token* (or (uiop:getenv "INFLUX_TOKEN")        "YOUR_TOKEN"))

(defparameter *categories-file*
  (or (uiop:getenv "CATEGORIES_FILE")
      (namestring (merge-pathnames "bank-categories.txt" (uiop:getcwd))))
  "Path to category rules file.")

;;; ──────────────────────────────────────────────────────────────────
;;; Category rules loader (same as bank-csv-to-influx.lisp)
;;; ──────────────────────────────────────────────────────────────────

(defun load-category-rules (&optional (path *categories-file*))
  (unless (probe-file path)
    (format t "~&[ERROR] Categories file not found: ~A~%" path)
    (return-from load-category-rules nil))
  (format t "~&[INFO] Loading rules from ~A~%" path)
  (with-open-file (in path :direction :input)
    (loop for line = (read-line in nil nil)
          while line
          for clean = (string-trim '(#\Space #\Return #\Tab) line)
          unless (or (string= clean "")
                     (and (> (length clean) 0) (char= (char clean 0) #\#)))
            collect (let ((colon (position #\: clean)))
                      (when colon
                        (cons (format nil "(?i)~A" (subseq clean (1+ colon)))
                              (subseq clean 0 colon))))
            into rules
          finally (return (remove nil rules)))))

(defun categorize (description rules)
  (loop for (pattern . category) in rules
        when (cl-ppcre:scan pattern description)
          return category
        finally (return "other")))

;;; ──────────────────────────────────────────────────────────────────
;;; URL encode helper
;;; ──────────────────────────────────────────────────────────────────

(defun url-encode (s)
  (with-output-to-string (out)
    (loop for ch across s
          do (if (or (char<= #\a ch #\z) (char<= #\A ch #\Z)
                     (char<= #\0 ch #\9) (member ch '(#\- #\_ #\. #\~)))
                 (write-char ch out)
                 (format out "%~2,'0X" (char-code ch))))))

;;; ──────────────────────────────────────────────────────────────────
;;; Fetch all transactions from InfluxDB via Flux query
;;; Returns a list of plists with :time-ns :amount :balance :description
;;;                                :account :category
;;; ──────────────────────────────────────────────────────────────────

(defun influx-query (flux)
  "Run a Flux query and return the raw CSV response string."
  (handler-case
      (dex:post (format nil "~A/api/v2/query?org=~A" *influx-url* (url-encode *influx-org*))
                :headers `(("Authorization" . ,(format nil "Token ~A" *influx-token*))
                           ("Content-Type"  . "application/vnd.flux")
                           ("Accept"        . "application/csv"))
                :content flux)
    (error (e)
      (format t "~&[ERROR] Query failed: ~A~%" e)
      nil)))

(defun parse-csv-line (line)
  "Split a CSV line into fields."
  (let ((fields '()) (current (make-string-output-stream)) (in-quotes nil))
    (loop for ch across line
          do (cond ((and (char= ch #\") (not in-quotes)) (setf in-quotes t))
                   ((and (char= ch #\") in-quotes)      (setf in-quotes nil))
                   ((and (char= ch #\,) (not in-quotes))
                    (push (get-output-stream-string current) fields)
                    (setf current (make-string-output-stream)))
                   (t (write-char ch current))))
    (push (get-output-stream-string current) fields)
    (nreverse fields)))

(defun fetch-all-transactions ()
  "Fetch all bank_transaction records from InfluxDB."
  (format t "~&[INFO] Fetching all transactions from InfluxDB...~%")
  (let* ((flux (format nil "from(bucket: ~S)
  |> range(start: 2000-01-01T00:00:00Z)
  |> filter(fn: (r) => r._measurement == \"bank_transaction\")
  |> pivot(rowKey: [\"_time\", \"account\", \"category\"], columnKey: [\"_field\"], valueColumn: \"_value\")"
                       *influx-bucket*))
         (response (influx-query flux)))
    (when (null response)
      (return-from fetch-all-transactions nil))

    (let* ((lines   (cl-ppcre:split "\\n|\\r\\n" response))
           (headers nil)
           (results '()))
      (dolist (line lines)
        (let ((clean (string-trim '(#\Space #\Return #\Tab) line)))
          (cond
            ((string= clean "") nil)
            ((cl-ppcre:scan "^#" clean) nil)
            ((and (null headers) (cl-ppcre:scan "_time" clean))
             (setf headers (mapcar (lambda (h) (string-trim " " h))
                                   (parse-csv-line clean))))
            ((and headers (cl-ppcre:scan "^," clean))
             (let* ((fields (parse-csv-line clean))
                    (row    (loop for h in headers
                                  for v in fields
                                  collect (cons h (string-trim " " v)))))
               (push row results))))))
      (format t "~&[INFO] Fetched ~A transaction rows~%" (length results))
      (nreverse results))))

;;; ──────────────────────────────────────────────────────────────────
;;; Delete all existing bank_transaction records
;;; ──────────────────────────────────────────────────────────────────

(defun delete-all-transactions ()
  "Delete all bank_transaction records from the banking bucket."
  (format t "~&[INFO] Deleting existing transactions...~%")
  (handler-case
      (progn
        (dex:post (format nil "~A/api/v2/delete?org=~A&bucket=~A"
                          *influx-url*
                          (url-encode *influx-org*)
                          (url-encode *influx-bucket*))
                  :headers `(("Authorization" . ,(format nil "Token ~A" *influx-token*))
                             ("Content-Type"  . "application/json"))
                  :content "{\"start\":\"2000-01-01T00:00:00Z\",\"stop\":\"2100-01-01T00:00:00Z\",\"predicate\":\"_measurement=\\\"bank_transaction\\\"\"}")
        (format t "~&[OK] Deleted existing transactions.~%")
        t)
    (error (e)
      (format t "~&[ERROR] Delete failed: ~A~%" e)
      nil)))

;;; ──────────────────────────────────────────────────────────────────
;;; Re-write transactions with new categories
;;; ──────────────────────────────────────────────────────────────────

(defun escape-tag (s)
  (with-output-to-string (out)
    (loop for ch across (format nil "~A" s)
          do (when (member ch '(#\Space #\, #\=)) (write-char #\\ out))
             (write-char ch out))))

(defun escape-field-string (s)
  (with-output-to-string (out)
    (loop for ch across (format nil "~A" s)
          do (when (char= ch #\") (write-char #\\ out))
             (write-char ch out))))

(defun parse-number (s)
  (let ((v (ignore-errors (with-input-from-string (in s) (read in)))))
    (when (numberp v) (float v))))

(defun row-to-line-protocol (row new-category)
  "Convert a transaction row plist to InfluxDB line protocol with updated category."
  (let* ((time-str    (cdr (assoc "_time"       row :test #'equal)))
         (account     (cdr (assoc "account"     row :test #'equal)))
         (description (cdr (assoc "description" row :test #'equal)))
         (amount-str  (cdr (assoc "amount"      row :test #'equal)))
         (balance-str (cdr (assoc "balance"     row :test #'equal))))
    (when (and time-str account amount-str
               (not (string= time-str ""))
               (not (string= amount-str "")))
      (let* ((ts (handler-case
                     (* (local-time:timestamp-to-unix
                          (local-time:parse-timestring time-str))
                        1000000000)
                   (error () nil)))
             (amount  (handler-case (parse-number amount-str) (error () nil)))
             (balance (when (and balance-str (not (string= balance-str "")))
                        (handler-case (parse-number balance-str) (error () nil)))))
        (when (and ts amount)
          (format nil "bank_transaction,account=~A,category=~A amount=~,4F~A,description=\"~A\" ~D"
                  (escape-tag account)
                  (escape-tag new-category)
                  amount
                  (if balance (format nil ",balance=~,4F" balance) "")
                  (escape-field-string (or description ""))
                  ts))))))

(defun parse-number (s)
  (let ((v (ignore-errors (with-input-from-string (in s) (read in)))))
    (when (numberp v) (float v))))

(defun write-to-influx (lines)
  (when lines
    (let ((body (format nil "~{~A~%~}" lines)))
      (handler-case
          (progn
            (dex:post (format nil "~A/api/v2/write?org=~A&bucket=~A&precision=ns"
                              *influx-url* (url-encode *influx-org*) (url-encode *influx-bucket*))
                      :headers `(("Authorization" . ,(format nil "Token ~A" *influx-token*))
                                 ("Content-Type"  . "text/plain; charset=utf-8"))
                      :content body)
            t)
        (dex:http-request-failed (e)
          (format t "~&[ERROR] Write HTTP ~A: ~A~%" (dex:response-status e) (dex:response-body e))
          nil)
        (error (e)
          (format t "~&[ERROR] Write failed: ~A~%" e)
          nil)))))

;;; ──────────────────────────────────────────────────────────────────
;;; Main
;;; ──────────────────────────────────────────────────────────────────

(defun main ()
  (format t "~&Bank transaction recategorizer~%")
  (format t "~&  InfluxDB : ~A  bucket=~A~%" *influx-url* *influx-bucket*)
  (format t "~&  Rules    : ~A~%~%" *categories-file*)

  (let ((rules (load-category-rules)))
    (unless rules
      (format t "~&[ERROR] No rules loaded — aborting.~%")
      (return-from main))
    (format t "~&[INFO] Loaded ~A category rules~%" (length rules))

    ;; 1. Fetch all existing transactions
    (let ((rows (fetch-all-transactions)))
      (unless rows
        (format t "~&[ERROR] No transactions fetched — aborting.~%")
        (return-from main))

      ;; 2. Build new line-protocol with updated categories
      (let* ((lines (loop for row in rows
                          for desc     = (or (cdr (assoc "description" row :test #'equal)) "")
                          for new-cat  = (categorize desc rules)
                          for old-cat  = (or (cdr (assoc "category" row :test #'equal)) "other")
                          for line     = (row-to-line-protocol row new-cat)
                          when line
                            do (unless (string= old-cat new-cat)
                                 (format t "~&[RECATEGORIZED] ~A: ~A → ~A~%"
                                         desc old-cat new-cat))
                            and collect line))
             (total    (length rows))
             (changed  (count-if (lambda (row)
                                   (let* ((desc    (or (cdr (assoc "description" row :test #'equal)) ""))
                                          (new-cat (categorize desc rules))
                                          (old-cat (or (cdr (assoc "category" row :test #'equal)) "other")))
                                     (not (string= old-cat new-cat))))
                                 rows)))
        (format t "~&[INFO] ~A transactions total, ~A will be recategorized~%" total changed)

        ;; 3. Confirm before destructive operation
        (format t "~&[WARN] This will DELETE and REWRITE all ~A transactions.~%" total)
        (format t "~&       Type YES to proceed: ")
        (force-output)
        (let ((input (string-trim " " (read-line))))
          (unless (string= input "YES")
            (format t "~&[INFO] Aborted.~%")
            (return-from main)))

        ;; 4. Delete old records
        (unless (delete-all-transactions)
          (format t "~&[ERROR] Delete failed — aborting to avoid data loss.~%")
          (return-from main))

        ;; 5. Write new records in batches of 500
        (format t "~&[INFO] Writing ~A updated transactions...~%" (length lines))
        (loop for batch-start from 0 by 500
              while (< batch-start (length lines))
              for batch-end = (min (+ batch-start 500) (length lines))
              for batch = (subseq lines batch-start batch-end)
              for batch-num from 1
              do (format t "~&[INFO] Writing batch ~A (~A lines)...~%" batch-num (length batch))
                 (write-to-influx batch))

        (format t "~&[OK] Recategorization complete. ~A transactions rewritten.~%" (length lines))))))

(main)
