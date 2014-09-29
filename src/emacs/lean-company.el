;; -*- lexical-binding: t; -*-
;; Copyright (c) 2014 Microsoft Corporation. All rights reserved.
;; Released under Apache 2.0 license as described in the file LICENSE.
;;
;; Author: Soonho Kong
;;
(require 'company)
(require 'company-etags)
(require 'dash)
(require 'dash-functional)
(require 'f)
(require 's)
(require 'lean-tags)
(require 'lean-server)

(defun company-lean-hook ()
  (set (make-local-variable 'company-backends) '(company-lean--import
                                                 company-lean--findg
                                                 company-lean--findp))
  (setq-local company-tooltip-limit 20)                      ; bigger popup window
  (setq-local company-idle-delay nil)                        ; decrease delay before autocompletion popup shows
  (setq-local company-echo-delay 0)                          ; remove annoying blinking
  (setq-local company-begin-commands '(self-insert-command)) ; start autocompletion only after typing
  (company-mode t))

(defun company-lean--check-prefix ()
  "Check whether to use company-lean or not"
  (or (company-lean--import-prefix)
      (company-lean--findg-prefix)
      (company-lean--findp-prefix)))

(defun company-lean--import-remove-lean (file-name)
  (cond
   ((s-ends-with? "/default.lean" file-name)
    (s-left (- (length file-name)
                   (length "/default.lean"))
                file-name))
   ((s-ends-with? ".lean" file-name)
    (s-left (- (length file-name)
                   (length ".lean"))
                file-name))
   (t file-name)))

(defun company-lean--import-candidates-main (root-dir)
  (when root-dir
    (let* ((lean-files (f-files root-dir
                                (lambda (file) (equal (f-ext file) "lean"))
                                t))
           ;; Relative to project root-dir
           (lean-files-r (--map (f-relative it root-dir) lean-files))
           (candidates
            (--map (s-replace-all `((,(f-path-separator)  . "."))
                                  (company-lean--import-remove-lean it))
                   lean-files-r)))
      (--zip-with (propertize it 'file-name other) candidates lean-files))))

(defun company-lean--import-prefix ()
  "FINDG is triggered when it looks at '_'"
  (when (looking-back
         (rx "import"
             (* (+ white)
                (+ (or alnum digit "." "_")))
             (? (+ white))))
    (company-grab-symbol)))

(defun company-lean--import-candidates (prefix)
  (let* ((cur-dir (f-dirname (buffer-file-name)))
         (parent-dir (f-parent cur-dir))
         (project-dir (f--traverse-upwards (f-exists? (f-expand ".project" it))
                                           (f-dirname (buffer-file-name))))
         (candidates
          (cond
           ;; prefix = ".."
           ((and parent-dir (s-starts-with? ".." prefix))
            (--map (concat ".." it)
                   (company-lean--import-candidates-main parent-dir)))
           ;; prefix = "."
           ((s-starts-with? "." prefix)
            (--map (concat "." it)
                   (company-lean--import-candidates-main cur-dir)))
           ;; normal prefix
           (t (-flatten
               (-map 'company-lean--import-candidates-main
                     (lean-path-list)))))))
    (--filter (s-starts-with? prefix it) candidates)))

(defun company-lean--import-location (arg)
  (let ((file-name (get-text-property 0 'file-name arg)))
    `(,file-name . 1)))

(defun company-lean--import (command &optional arg &rest ignored)
  (case command
    (prefix (company-lean--import-prefix))
    (candidates (company-lean--import-candidates arg))
    (location   (company-lean--import-location arg))
    (sorted t)))

;; FINDG
;; =====

(defun company-lean--findg-prefix ()
  "FINDG is triggered when it looks at '_'"
  (when (looking-at (rx symbol-start "_")) ""))

(defun company-lean--findg-candidates (prefix)
  (let ((line-number (line-number-at-pos))
        (column-number (current-column))
        pattern)
    (lean-server-send-cmd-sync (lean-cmd-wait) '(lambda () ()))
    (setq pattern (if current-prefix-arg
                      (read-string "Filter for find declarations (e.g: +intro -and): " "" nil "")
                    ""))
    (lean-server-send-cmd-sync (lean-cmd-findg line-number column-number pattern)
                               (lambda (candidates)
                                 (lean-debug "executing continuation for FINDG")
                                 (--map (company-lean--findp-make-candidate it prefix) candidates)))))

(defun company-lean--findg-pre-completion (args)
  "Delete current '_' before filling the selected AC candidate"
  (when (looking-at (rx "_"))
    (delete-forward-char 1)))

(defun company-lean--findg (command &optional arg &rest ignored)
  (case command
    (prefix (company-lean--findg-prefix))
    (candidates (company-lean--findg-candidates arg))
    (annotation (company-lean--findp-annotation arg))
    (location (company-lean--findp-location arg))
    (pre-completion (company-lean--findg-pre-completion arg))
    (sorted t)))

;; FINDP
;; -----
(defun company-lean--need-autocomplete ()
  (not (looking-back
        (rx (or "theorem" "definition" "lemma" "axiom" "parameter"
                "variable" "hypothesis" "conjecture"
                "corollary" "open")
            (+ white)
            (* (not white))))))

(defun company-lean--findp-prefix ()
  "Returns the symbol to complete. Also, if point is on a dot,
triggers a completion immediately."
  (let ((prefix (company-grab-symbol)))
    (when (and
           prefix
           (company-lean--need-autocomplete)
           (or
            (>= (length prefix) 1)
            (string-match "[_.]" prefix)))
      (when (s-starts-with? "@" prefix)
        (setq prefix (substring prefix 1)))
      prefix)))

(defun company-lean--findp-make-candidate (arg prefix)
  (let* ((text  (car arg))
         (type  (cdr arg))
         (start (s-index-of prefix text)))
    (propertize text
                'type  type
                'start start
                'prefix prefix)))

(defun company-lean--findp-candidates (prefix)
  (let ((line-number (line-number-at-pos))
        (column-number (current-column))
        pattern)
    (lean-server-send-cmd-sync (lean-cmd-wait) '(lambda () ()))
    (lean-server-send-cmd-sync (lean-cmd-findp line-number prefix)
                               (lambda (candidates)
                                 (lean-debug "executing continuation for FINDP")
                                 (--map (company-lean--findp-make-candidate it prefix) candidates)))))

(defun company-lean--findp-location (arg)
  (lean-generate-tags)
  (let ((tags-table-list (company-etags-buffer-table)))
    (when (fboundp 'find-tag-noselect)
      (save-excursion
        (let ((buffer (find-tag-noselect arg)))
          (cons buffer (with-current-buffer buffer (point))))))))

(defun company-lean--findp-annotation (candidate)
  (let ((type (get-text-property 0 'type candidate)))
    (when type
      (let* ((annotation-str (format " : %s" type))
             (annotation-len (length annotation-str))
             (candidate-len  (length candidate))
             (entry-width    (+ candidate-len
                                annotation-len))
             (allowed-width  (truncate (* 0.90 (window-body-width)))))
        (when (> entry-width allowed-width)
          (setq annotation-str
                (concat
                 (substring-no-properties annotation-str
                                         0
                                         (- allowed-width candidate-len 3))
                 "...")))
        annotation-str))))

(defun company-lean--findp-match (arg)
  "Return the end of matched region"
  (let ((prefix (get-text-property 0 'prefix arg))
        (start  (get-text-property 0 'start  arg)))
    (if start
        (+ start (length prefix))
      0)))

(defun company-lean--findp (command &optional arg &rest ignored)
  (case command
    (prefix (company-lean--findp-prefix))
    (candidates (company-lean--findp-candidates arg))
    (annotation (company-lean--findp-annotation arg))
    (location (company-lean--findp-location arg))
    (match (company-lean--findp-match arg))
    (no-cache t)
    (require-match 'never)
    (sorted t)))

;; ADVICES
;; =======

(defadvice company--window-width
    (after lean-company--window-width activate)
  (when (eq major-mode 'lean-mode)
    (setq ad-return-value (truncate (* 0.95 (window-body-width))))))

(defun replace-regex-return-position (regex rep string &optional start)
  "Find regex and replace with rep on string.

Return replaced string and start and end positions of replacement."
  (let* ((start   (or start 0))
         (len     (length string))
         (m-start (string-match regex string start))
         (m-end   (match-end 0))
         pre-string post-string matched-string replaced-string result)
    (cond (m-start
           (setq pre-string     (substring string 0 m-start))
           (setq matched-string (substring string m-start m-end))
           (setq post-string    (substring string m-end))
           (string-match regex matched-string)
           (setq replaced-string
                 (replace-match rep nil nil matched-string))
           (setq result (concat pre-string
                                replaced-string
                                post-string))
           `(,result ,m-start ,(+ m-start (length replaced-string)))
           ))))

(defun replace-regex-add-properties-all (regex rep string properties)
  "Find all occurrences of regex in string, and replace them with
rep. Then, add text-properties on the replaced region."
  (let ((replace-result-items (replace-regex-return-position regex rep string))
        (result string))
    (while replace-result-items
      (pcase replace-result-items
        (`(,replaced-string ,m-start ,m-end)
         (setq result replaced-string)
         (add-text-properties m-start m-end properties result)
         (setq replace-result-items
               (replace-regex-return-position regex rep result m-end)))))
    result))

(eval-after-load 'company
  '(defadvice company-fill-propertize
     (after lean-company-fill-propertize activate)
     (when (eq major-mode 'lean-mode)
       (let* ((selected (ad-get-arg 3))
              (foreground-color lean-company-type-foreground)
              (background-color (if selected (face-background 'company-tooltip-selection)
                                  (face-background 'company-tooltip)))
              (face-attrs
               (cond (background-color `(:foreground ,foreground-color
                                         :background ,background-color))
                     (t `(:foreground ,foreground-color))))
              (properties `(face       ,face-attrs
                                       mouse-face company-tooltip))
              (old-return ad-return-value)
              (old-len    (length old-return))
              new-return new-len)
         (setq new-return
               (replace-regex-add-properties-all
                (rx "?" word-start (group (+ (not white))) word-end)
                "\\1"
                ad-return-value
                properties))
         (setq new-len (length new-return))
         (while (< (length new-return) old-len)
           (setq new-return
                 (concat new-return " ")))
         (when background-color
           (add-text-properties new-len old-len properties new-return))
         (setq ad-return-value new-return)))))

(provide 'lean-company)
