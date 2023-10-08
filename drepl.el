;;; drepl.el --- REPL protocol for the dumb terminal   -*- lexical-binding: t; -*-

;; Copyright (C) 2023  Augusto Stoffel

;; Author: Augusto Stoffel <arstoffel@gmail.com>
;; Keywords: languages, processes

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; 

;;; Code:

(require 'cl-lib)
(require 'comint)
(eval-when-compile (require 'subr-x))

;;; Variables and customization options

(defgroup drepl nil
  "REPL protocol for the dumb terminal."
  :group 'comint
  :link '(url-link "https://github.com/astoff/drepl"))

(defface drepl-prompt-incomplete '((t :inherit (comint-highlight-prompt default)))
  "Face for continuation prompts when input is incomplete but valid.")

(defface drepl-prompt-invalid '((t :inherit (error default)))
  "Face for continuation prompts when input is invalid.")

(defvar-local drepl--current nil
  "dREPL associated to the current buffer.")

(defvar drepl--verbose t)

;;; Basic definitions

(cl-defstruct drepl
  "Base dREPL object."
  buffer
  status
  (last-request-id 0)
  requests
  pending)

(cl-defgeneric drepl-process (repl)
  (get-buffer-process (drepl-buffer repl)))

(defun drepl--get-repl (&optional status)
  (let ((repl drepl--current))          ;TODO: choose one interactively, maybe
    (when (or (not status)
              (and (memq (process-status (drepl-process repl)) '(run open))
                   (eq status (drepl-status repl))))
      repl)))

(defsubst drepl--message (format-string &rest args)
  (when drepl--verbose
    (apply #'message format-string args)))

;;; Communication protocol

(defalias 'drepl--json-decode
  (if (json-available-p)
      (lambda (s)
        (json-parse-string s :object-type 'alist))
    (error "Not implemented")))

(defalias 'drepl--json-encode
  (if (json-available-p)
      (lambda (s) (json-serialize s :null-object nil))
    (error "Not implemented")))

(cl-defgeneric drepl--send-request (repl data)
  (drepl--message "OUT: %s" (json-serialize data))
  (setf (drepl-status repl) 'busy)
  (process-send-string (drepl-process repl)
                       (format "\e%%%s\n" (json-serialize data))))

(cl-defgeneric drepl--communicate (repl callback op &rest args)
  (if (eq callback 'sync)
      (progn (unless (eq (drepl-status repl) 'ready)
               (user-error "%s is busy" repl))
             (let* ((result :none)
                    (cb (lambda (data) (setq result data))))
               (apply #'drepl--communicate repl cb op args)
               (while (eq result :none) (accept-process-output))
               result))
    (let* ((id (cl-incf (drepl-last-request-id repl)))
           (data `(:id ,id :op ,(symbol-name op) ,@args)))
      (push (cons id callback) (if-let ((reqs (drepl-requests repl)))
                                   (cdr reqs)
                                 (drepl-requests repl)))
      (if (eq 'ready (drepl-status repl))
          (drepl--send-request repl data)
        (push (cons id data) (drepl-pending repl)))
      id)))

(cl-defgeneric drepl--handle-notification (repl data)
  (pcase (alist-get 'op data)
    ("status" (setf (drepl-status repl)
                    (intern (alist-get 'status data))))
    ("log" (drepl--message "dREPL buffer %s: %s"
                           (buffer-name)
                           (alist-get 'text data)))))

(defun drepl--osc-handler (_cmd text)
  (drepl--message " IN: %s" text)
  (let* ((data (drepl--json-decode text))
         (id (alist-get 'id data))
         (callback (if id
                       (prog1
                           (alist-get id (drepl-requests drepl--current))
                         (setf (alist-get id (drepl-requests drepl--current)
                                          nil 'remove)
                               nil))
                     (apply-partially #'drepl--handle-notification
                                      drepl--current))))
    (when-let ((nextreq (and (eq (drepl-status drepl--current) 'ready)
                             (pop (drepl-pending drepl--current)))))
      (drepl--send-request drepl--current nextreq))
    (when callback
      (funcall callback data))))

;;; Complete operation

(defun drepl--capf-annotate (cand)
  "Return an annotation for completion candidate CAND."
  (get-text-property 0 'drepl--annot cand))

(cl-defgeneric drepl--completion-bounds (_repl)
  (bounds-of-thing-at-point 'symbol))

(cl-defgeneric drepl--completion-cadidates (repl code offset)
  (let ((response (while-no-input
                    (drepl--communicate repl 'sync 'complete
                                        :code code
                                        :offset offset))))
    (mapcar (lambda (c)
              (let-alist c
                (propertize .text 'drepl--annot .annotation)))
            (alist-get 'candidates response))))

(defun drepl--complete ()
  (when-let ((repl (when (derived-mode-p 'drepl-mode)
                     (drepl--get-repl 'ready)))
             (bounds (drepl--completion-bounds repl))
             (code (buffer-substring-no-properties
                    (cdr comint-last-prompt)
                    (point-max)))
             (offset (- (point) (cdr comint-last-prompt)))
             (cands (when (>= offset 0)
                      (drepl--completion-cadidates repl code offset)))
             (metadata '(metadata
                         (category . drepl)
                         (annotation-function . drepl--capf-annotate)))
             (coll (lambda (string predicate action)
                     (if (eq action 'metadata)
                         metadata
                       (complete-with-action action cands string predicate)))))
    `(,(car bounds) ,(cdr bounds) ,coll)))

;;; Eval operation

(cl-defgeneric drepl--eval (repl code)
  (drepl--communicate repl #'ignore 'eval :code code))

(defun drepl--send-string (proc string)
  "Like `comint-send-string', but checks whether PROC's status is `ready'.
If it is, then make an eval request, otherwise just send the raw
STRING to the process."
  (drepl--message "SND: %s" string)
  (let ((repl (with-current-buffer
                  (if proc (process-buffer proc) (current-buffer))
                (drepl--get-repl 'ready))))
    (if repl
        (drepl--eval repl string)
      (comint-simple-send proc string))))

(defun drepl-eval (code)
  (interactive (list (read-from-minibuffer "Evaluate: ")))
  (drepl--eval (drepl--get-repl) code))

(defun drepl-send-input-maybe (&optional force) ;Change this to `newline', with opposite logic
  "Like `comint-send-input', but first check if input is complete.
If the input is incomplete or invalid code and FORCE is nil,
insert start a continuation line instead."
  (interactive "P")
  (unless (derived-mode-p 'drepl-mode)
    (user-error "Can't run this command here."))
  (let-alist (when-let ((repl (unless force (drepl--get-repl 'ready)))
                        (pmark (process-mark (drepl-process repl)))
                        (code (and (>= (point) pmark)
                                   (buffer-substring-no-properties
                                    pmark (field-end)))))
               (drepl--communicate drepl--current 'sync 'checkinput
                                   :code code))
    (pcase-exhaustive .status
      ((or (and "incomplete" (let face 'drepl-prompt-incomplete))
           (and "invalid" (let face 'drepl-prompt-invalid)))
       (let* ((prompt (thread-first
                       .prompt
                       (or "")
                       (propertize 'font-lock-face face))))
         (insert (propertize "\n" 'display (concat " \n" prompt))
                 .indent)))
      ((or "complete" 'nil)
       (comint-send-input)))))

;;; Describe operation

(cl-defgeneric drepl--describe (repl callback)
  (when-let ((offset (- (point) (cdr comint-last-prompt)))
             (code (when (>= offset 0)
                     (buffer-substring-no-properties
                      (cdr comint-last-prompt)
                      (point-max)))))
    (drepl--communicate repl callback 'describe :code code :offset offset)))

(defun drepl--make-help-buffer (data &optional interactive)
  (let-alist data
    (help-setup-xref (list #'drepl--make-help-buffer data) interactive)
    (with-help-window (help-buffer)
      (with-current-buffer standard-output
        (when (stringp .name)
          (insert .name)
          (when (stringp .type) (insert " is a " .type))
          (when (stringp .file) (insert " defined in " (buttonize .file #'find-file .file)))
          (insert ".\n\n"))
        (when (stringp .text)
          (insert (ansi-color-apply .text)))))))

(defun drepl-describe-thing-at-point ()
  (interactive)
  (when-let ((repl (when (derived-mode-p 'drepl-mode)
                     (drepl--get-repl 'ready))))
    (drepl--describe repl #'drepl--make-help-buffer)))

;;; Initialization and restart

(cl-defgeneric drepl--restart (drepl)
  "Restart the REPL."
  (with-current-buffer (drepl-buffer drepl)
    (kill-process (drepl-process drepl--current))
    (while (accept-process-output (drepl-process drepl--current)))))

(defun drepl-restart ()
  (interactive)
  (when-let ((repl (drepl--get-repl)))
    (drepl--restart repl)))

;;; Base major mode

(defvar-keymap drepl-mode-map
  :doc "Keymap for `drepl-mode'."
  :parent comint-mode-map
  "<remap> <comint-send-input>" #'drepl-send-input-maybe
  "<remap> <display-local-help>" #'drepl-describe-thing-at-point
  "C-c C-n" #'drepl-restart)

(define-derived-mode drepl-mode comint-mode "dREPL"
  "Major mode for the dREPL buffers."
  :interactive nil
  (add-hook 'comint-output-filter-functions 'comint-osc-process-output)
  (push '("5161" . drepl--osc-handler) ansi-osc-handlers)
  (setq-local comint-input-sender #'drepl--send-string)
  (setq-local indent-line-function #'comint-indent-input-line-default)
  (add-hook 'completion-at-point-functions 'drepl--complete nil t))

(provide 'drepl)

;;; drepl.el ends here
