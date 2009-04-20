; -*- mode: lisp -*-

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Shared by client and server
;;;

(in-package :trubanc)

(defun escape (str)
  "Escape a string for inclusion in a message"
  (let ((res "")
        (ptr 0))
    (dotimes (i (length str))
      (let ((char (aref str i)))
        (when (position char "(),:.\\")
          (setq res (strcat res (subseq str ptr i) "\\"))
          (setq ptr i))))
    (strcat res (subseq str ptr))))

(defun simple-makemsg (&rest req)
  "Make an unsigned message"
  (loop
     with msg = "("
     for i from 0
     for value in req
     do
     (when (> i 0) (setq msg (strcat msg ",")))
     (setq msg (strcat msg (escape (string (or value "")))))
     finally
     (return (strcat msg ")"))))

(defun assetid (id scale precision name)
  "Return the id for an asset"
  (sha1 (format nil "~a,~a,~a,~a" id scale precision name)))

(defvar *patterns* nil)

;; Patterns for non-request data
(defun patterns ()
  (or *patterns*
      (let ((patterns `(;; Customer messages
                        (,$BALANCE .
                         (,$BANKID ,$TIME ,$ASSET ,$AMOUNT (,$ACCT)))
                        (,$OUTBOXHASH . (,$BANKID ,$TIME ,$COUNT ,$HASH))
                        (,$BALANCEHASH . (,$BANKID ,$TIME ,$COUNT ,$HASH))
                        (,$SPEND .
                         (,$BANKID ,$TIME ,$ID ,$ASSET ,$AMOUNT (,$NOTE)))
                        (,$ASSET .
                         (,$BANKID ,$ASSET ,$SCALE ,$PRECISION ,$ASSETNAME))
                        (,$STORAGE . (,$BANKID ,$TIME ,$ASSET ,$PERCENT))
                        (,$STORAGEFEE . (,$BANKID ,$TIME ,$ASSET ,$AMOUNT))
                        (,$FRACTION . (,$BANKID ,$TIME ,$ASSET ,$AMOUNT))
                        (,$REGISTER . (,$BANKID ,$PUBKEY (,$NAME)))
                        (,$SPENDACCEPT . (,$BANKID ,$TIME ,$ID (,$NOTE)))
                        (,$SPENDREJECT . (,$BANKID ,$TIME ,$ID (,$NOTE)))
                        (,$GETOUTBOX .(,$BANKID ,$REQ))
                        (,$GETINBOX . (,$BANKID ,$REQ))
                        (,$PROCESSINBOX . (,$BANKID ,$TIME ,$TIMELIST))
                        (,$STORAGEFEES . (,$BANKID ,$REQ))
                        (,$GETTIME . (,$BANKID ,$REQ))
                        (,$COUPONENVELOPE . (,$ID ,$ENCRYPTEDCOUPON))

                        ;; Bank signed messages
                        (,$FAILED . (,$MSG ,$ERRMSG))
                        (,$TOKENID . (,$TOKENID))
                        (,$BANKID . (,$BANKID))
                        (,$REGFEE . (,$BANKID ,$TIME ,$ASSET ,$AMOUNT))
                        (,$TRANFEE . (,$BANKID ,$TIME ,$ASSET ,$AMOUNT))
                        (,$TIME . (,$ID ,$TIME))
                        (,$INBOX . (,$TIME ,$MSG))
                        (,$REQ . (,$ID ,$REQ))
                        (,$COUPON .
                         (,$BANKURL ,$COUPON ,$ASSET ,$AMOUNT (,$NOTE)))
                        (,$COUPONNUMBERHASH . (,$COUPON))
                        (,$ATREGISTER . (,$MSG))
                        (,$ATOUTBOXHASH . (,$MSG))
                        (,$ATBALANCEHASH . (,$MSG))
                        (,$ATGETINBOX . (,$MSG))
                        (,$ATBALANCE . (,$MSG))
                        (,$ATSPEND . (,$MSG))
                        (,$ATTRANFEE . (,$MSG))
                        (,$ATASSET . (,$MSG))
                        (,$ATSTORAGE . (,$MSG))
                        (,$ATSTORAGEFEE . (,$MSG))
                        (,$ATFRACTION . (,$MSG))
                        (,$ATPROCESSINBOX . (,$MSG))
                        (,$ATSTORAGEFEES . (,$MSG))
                        (,$ATSPENDACCEPT . (,$MSG))
                        (,$ATSPENDREJECT . (,$MSG))
                        (,$ATGETOUTBOX . (,$MSG))
                        (,$ATCOUPON . (,$COUPON ,$SPEND))
                        (,$ATCOUPONENVELOPE . (,$MSG))
                        ))
            (hash (make-hash-table :test 'equal)))
        (loop
           for (key . value) in patterns
           do
             (setf (gethash key hash) value))
        (setq *patterns* hash))))

(defmethod dirhash ((db db) key unpacker &optional newitem removed-names)
  "Return the hash of a directory, KEY, of bank-signed messages.
    The hash is of the user messages wrapped by the bank signing.
    NEWITEM is a new item or an array of new items, not bank-signed.
    REMOVED-NAMES is a list of names in the KEY dir to remove.
    UNPACKER is a function to call with a single-arg, a bank-signed
    message. It returns a parsed and matched ARGS hash table whose $MSG
    element is the parsed user message wrapped by the bank signing.
    Returns two values, the sha1 hash of the items and the number of items."
  (let ((contents (db-contents db key))
        (items nil))
    (dolist (name contents)
      (unless (member name removed-names :test 'equal)
        (let* ((msg (db-get db (strcat key "/" name)))
               (args (funcall unpacker msg))
               (req (gethash $MSG args)))
          (unless req
            (error "Directory msg is not a bank-wrapped message"))
          (unless (setq msg (get-parsemsg req))
            (error "get-parsemsg didn't find anything"))
          (push msg items))))
    (if newitem
        (if (stringp newitem) (push newitem items))
        (setq items (append items newitem)))
    (setq items (sort items 'string-lessp))
    (let* ((str (apply 'implode "." (mapcar 'trim items)))
           (hash (sha1 str)))
      (values hash (length items)))))

(defmethod balancehash ((db db) unpacker balancekey acctbals)
  "Compute the balance hash as two values: hash & count.
   UNPACKER is a function of one argument, a string, representing
   a bank-signed message. It returns the unpackaged bank message
   BALANCEKEY is the key to the user balance directory.
   $acctbals is an alist of alists: ((acct . (assetid . msg)) ...)"
  (let* ((hash nil)
         (hashcnt 0)
         (accts (db-contents db balancekey))
         (needsort nil))
    (loop
       for  acct.bals in acctbals
       for acct = (car acct.bals)
       do
         (unless (member acct acct :test 'equal)
           (push acct accts)
           (setq needsort t)))
    (when needsort (setq accts (sort accts 'string-lessp)))
    (loop
       for acct in accts
       for newitems = nil
       for removed-names = nil
       for newacct = (cdr (assoc acct acctbals :test 'equal))
       do
         (when newacct
           (loop
              for (assetid . msg) in newacct
              do
                (push msg newitems)
                (push assetid removed-names)))
         (multiple-value-bind (hash1 cnt)
             (dirhash db (strcat balancekey "/" acct) unpacker
                      newitems removed-names)
           (setq hash (if hash (strcat hash "." hash1) hash1))
           (incf hashcnt cnt)))
    (when (> hashcnt 1) (setq hash (sha1 hash)))
    (values hash hashcnt)))

(defun hex-char-p (x)
  "Predicate. True if x is 0-9, a-f, or A-F"
  (check-type x character)
  (let ((code (char-code x)))
    (or (and (>= code #.(char-code #\0))
             (<= code #.(char-code #\9)))
        (and (>= code #.(char-code #\a))
             (<= code #.(char-code #\f)))
        (and (>= code #.(char-code #\A))
             (<= code #.(char-code #\F))))))

(defun coupon-number-p (x)
  "Predicate. True if arg looks like a coupon number."
  (and (stringp x)
       (eql 32 (length x))
       (every 'hex-char-p x)))

(defun id-p (x)
  "Predicate. True if arg looks like an ID."
  (and (stringp x)
       (eql 40 (length x))
       (every 'hex-char-p x)))

(defun fraction-digits (percent)
  "Calculate the number of digits to keep for the fractional balance.
   Add 3 for divide by 365, 2 for percent, 3 more for 1/1000 precision."
  (+ (number-precision percent) 8))

(defun storage-fee (balance baltime now percent digits)
  "Calculate the storage fee.
   BALANCE is the balance.
   BALTIME is the time of the BALANCE, as an integer string.
   NOW is the current time, as an integer string.
   PERCENT is the storage fee rate, in percent/year.
   DIGITS is the precision for the arithmetic.
   Returns two values:
    1) the storage fee
    2) balance - storage-fee"
  (wbp (digits)
    (cond ((eql 0 (bccomp percent 0))
           (values "0" balance))
          (t (let* ((secs-per-year-pct (* 60 60 24 365 100))
                    (fee (bcdiv (bcmul balance
                                       percent
                                       (wbp (0) (bcsub now baltime)))
                                secs-per-year-pct)))
               (cond ((< (bccomp fee 0) 0)
                      (setq fee  "0"))
                     ((> (bccomp fee balance) 0)
                      (setq fee balance)))
               (values (bcsub balance fee) fee))))))

(defun normalize-balance (balance fraction digits)
  "Add together BALANCE & FRACTION, to DIGITS precision.
   Return two values, the integer part and the fractional part."
  (wbp (digits)
    (split-decimal (bcadd balance fraction))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Copyright 2009 Bill St. Clair
;;;
;;; Licensed under the Apache License, Version 2.0 (the "License");
;;; you may not use this file except in compliance with the License.
;;; You may obtain a copy of the License at
;;;
;;;     http://www.apache.org/licenses/LICENSE-2.0
;;;
;;; Unless required by applicable law or agreed to in writing, software
;;; distributed under the License is distributed on an "AS IS" BASIS,
;;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;;; See the License for the specific language governing permissions
;;; and limitations under the License.
;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;