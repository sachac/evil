;;; evil-jumps.el --- Jump list implementation

;; Author: Bailey Ling <bling at live.ca>

;; Version: 1.2.10

;;
;; This file is NOT part of GNU Emacs.

;;; License:

;; This file is part of Evil.
;;
;; Evil is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; Evil is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Evil.  If not, see <http://www.gnu.org/licenses/>.

(eval-when-compile (require 'cl))

(require 'evil-core)
(require 'evil-states)

;;; Code:

(defgroup evil-jumps nil
  "Evil jump list configuration options."
  :prefix "evil-jumps"
  :group 'evil)

(defcustom evil-jumps-max-length 100
  "The maximum number of jumps to keep track of."
  :type 'integer
  :group 'evil-jumps)

(defcustom evil-jumps-pre-jump-hook nil
  "Hooks to run just before jumping to a location in the jump list."
  :type 'hook
  :group 'evil-jumps)

(defcustom evil-jumps-post-jump-hook nil
  "Hooks to run just after jumping to a location in the jump list."
  :type 'hook
  :group 'evil-jumps)

(defcustom evil-jumps-ignored-file-patterns '("COMMIT_EDITMSG$" "TAGS$")
  "A list of pattern regexps to match on the file path to exclude from being included in the jump list."
  :type '(repeat string)
  :group 'evil-jumps)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar evil--jumps-jumping nil)

(eval-when-compile (defvar evil--jumps-debug nil))

(defvar evil--jumps-buffer-targets "\\*\\(new\\|scratch\\)\\*"
  "Regexp to match against `buffer-name' to determine whether it's a valid jump target.")

(defvar evil--jumps-window-jumps (make-hash-table)
  "Hashtable which stores all jumps on a per window basis.")

(defvar evil-jumps-history nil
  "History of `evil-mode' jumps that are persisted with `savehist'.")

(cl-defstruct evil-jumps-struct
  ring
  (idx -1))

(defmacro evil--jumps-message (format &rest args)
  (when evil--jumps-debug
    `(with-current-buffer (get-buffer-create "*evil-jumps*")
       (goto-char (point-max))
       (insert (apply #'format ,format ',args) "\n"))))

(defun evil--jumps-get-current (&optional window)
  (unless window
    (setq window (frame-selected-window)))
  (let* ((jump-struct (gethash window evil--jumps-window-jumps)))
    (unless jump-struct
      (setq jump-struct (make-evil-jumps-struct))
      (puthash window jump-struct evil--jumps-window-jumps))
    jump-struct))

(defun evil--jumps-get-jumps (struct)
  (let ((ring (evil-jumps-struct-ring struct)))
    (unless ring
      (setq ring (make-ring evil-jumps-max-length))
      (setf (evil-jumps-struct-ring struct) ring))
    ring))

(defun evil--jumps-get-window-jump-list ()
  (let ((struct (evil--jumps-get-current)))
    (evil--jumps-get-jumps struct)))

(defun evil--jumps-savehist-sync ()
  "Updates the printable value of window jumps for `savehist'."
  (setq evil-jumps-history
        (cl-remove-if-not #'identity
                          (mapcar #'(lambda (jump)
                                      (let* ((mark (car jump))
                                             (pos (if (markerp mark)
                                                      (marker-position mark)
                                                    mark))
                                             (file-name (cadr jump)))
                                        (if (and (not (file-remote-p file-name))
                                                 (file-exists-p file-name)
                                                 pos)
                                            (list pos file-name)
                                          nil)))
                                  (ring-elements (evil--jumps-get-window-jump-list))))))

(defun evil--jumps-jump-to-index (idx)
  (let ((target-list (evil--jumps-get-window-jump-list)))
    (evil--jumps-message "jumping to %s" idx)
    (evil--jumps-message "target list = %s" target-list)
    (when (and (< idx (ring-length target-list))
               (>= idx 0))
      (run-hooks 'evil-jumps-pre-jump-hook)
      (setf (evil-jumps-struct-idx (evil--jumps-get-current)) idx)
      (let* ((place (ring-ref target-list idx))
             (pos (car place))
             (file-name (cadr place)))
        (setq evil--jumps-jumping t)
        (if (string-match-p evil--jumps-buffer-targets file-name)
            (switch-to-buffer file-name)
          (find-file file-name))
        (setq evil--jumps-jumping nil)
        (goto-char pos)
        (run-hooks 'evil-jumps-post-jump-hook)))))

(defun evil--jumps-push ()
  "Pushes the current cursor/file position to the jump list."
  (let ((target-list (evil--jumps-get-window-jump-list)))
    (let ((file-name (buffer-file-name))
          (buffer-name (buffer-name))
          (current-pos (point-marker))
          (first-pos nil)
          (first-file-name nil)
          (excluded nil))
      (when (and (not file-name)
                 (string-match-p evil--jumps-buffer-targets buffer-name))
        (setq file-name buffer-name))
      (when file-name
        (dolist (pattern evil-jumps-ignored-file-patterns)
          (when (string-match-p pattern file-name)
            (setq excluded t)))
        (unless excluded
          (unless (ring-empty-p target-list)
            (setq first-pos (car (ring-ref target-list 0)))
            (setq first-file-name (car (cdr (ring-ref target-list 0)))))
          (unless (and (equal first-pos current-pos)
                       (equal first-file-name file-name))
            (evil--jumps-message "pushing %s on %s" current-pos file-name)
            (ring-insert target-list `(,current-pos ,file-name))))))
    (evil--jumps-message "%s %s"
                         (selected-window)
                         (and (not (ring-empty-p target-list))
                              (ring-ref target-list 0)))))

(evil-define-command evil-show-jumps ()
  "Display the contents of the jump list."
  :repeat nil
  (evil-with-view-list "evil-jumps"
    (require 'tabulated-list)
    (setq tabulated-list-format [("Jump" 5 t)
                                 ("Marker" 8 t)
                                 ("File/text" 1000 t)])
    (tabulated-list-init-header)
    (setq tabulated-list-entries
          (lambda ()
            (let* ((jumps (evil--jumps-savehist-sync))
                   (count 0))
              (cl-loop for jump in jumps
                       collect `(,(incf count) [,(number-to-string count)
                                                ,(number-to-string (car jump))
                                                ,(cdr jump)])))))
    (tabulated-list-print)))

(defun evil-set-jump (&optional pos)
  "Set jump point at POS.
POS defaults to point."
  (unless (or (region-active-p) (evil-visual-state-p))
    (evil-save-echo-area
      (push-mark pos t)))

  (unless evil--jumps-jumping
    ;; clear out intermediary jumps when a new one is set
    (let* ((struct (evil--jumps-get-current))
           (target-list (evil--jumps-get-jumps struct))
           (idx (evil-jumps-struct-idx struct)))
      (cl-loop repeat idx
               do (ring-remove target-list))
      (setf (evil-jumps-struct-idx struct) -1))
    (evil--jumps-push)))

(defun evil--jump-backward (count)
  (let ((count (or count 1)))
    (evil-motion-loop (nil count)
      (let* ((struct (evil--jumps-get-current))
             (idx (evil-jumps-struct-idx struct)))
        (evil--jumps-message "jumping back %s" idx)
        (when (= idx -1)
          (setq idx (+ idx 1))
          (setf (evil-jumps-struct-idx struct) 0)
          (evil--jumps-push))
        (evil--jumps-jump-to-index (+ idx 1))))))

(defun evil--jump-forward (count)
  (let ((count (or count 1)))
    (evil-motion-loop (nil count)
      (let* ((struct (evil--jumps-get-current))
             (idx (evil-jumps-struct-idx struct)))
        (evil--jumps-jump-to-index (- idx 1))))))

(defun evil--jumps-window-configuration-hook (&rest args)
  (let* ((window-list (window-list-1 nil nil t))
         (existing-window (selected-window))
         (new-window (previous-window)))
    (when (and (not (eq existing-window new-window))
               (> (length window-list) 1))
      (let* ((target-jump-struct (evil--jumps-get-current new-window))
             (target-jump-count (ring-length (evil--jumps-get-jumps target-jump-struct))))
        (if (not (ring-empty-p (evil--jumps-get-jumps target-jump-struct)))
            (evil--jumps-message "target window %s already has %s jumps" new-window target-jump-count)
          (evil--jumps-message "new target window detected; copying %s to %s" existing-window new-window)
          (let* ((source-jump-struct (evil--jumps-get-current existing-window))
                 (source-list (evil--jumps-get-jumps source-jump-struct)))
            (when (= (ring-length (evil--jumps-get-jumps target-jump-struct)) 0)
              (setf (evil-jumps-struct-idx target-jump-struct) (evil-jumps-struct-idx source-jump-struct))
              (setf (evil-jumps-struct-ring target-jump-struct) (ring-copy source-list)))))))
    ;; delete obsolete windows
    (maphash (lambda (key val)
               (unless (member key window-list)
                 (evil--jumps-message "removing %s" key)
                 (remhash key evil--jumps-window-jumps)))
             evil--jumps-window-jumps)))

(defun evil--jump-hook (&optional command)
  "Set jump point if COMMAND has a non-nil :jump property."
  (setq command (or command this-command))
  (when (evil-get-command-property command :jump)
    (evil-set-jump)))

(defadvice switch-to-buffer (before evil-jumps activate)
  (evil-set-jump))

(defadvice split-window-internal (before evil-jumps activate)
  (evil-set-jump))

(defadvice find-tag-noselect (before evil-jumps activate)
  (evil-set-jump))

(add-hook 'evil-local-mode-hook
          (lambda ()
            (if evil-local-mode
                (progn
                  (add-hook 'pre-command-hook #'evil--jump-hook nil t)
                  (add-hook 'next-error-hook #'evil-set-jump nil t)
                  (add-hook 'window-configuration-change-hook #'evil--jumps-window-configuration-hook nil t))
              (progn
                (remove-hook 'pre-command-hook #'evil--jump-hook t)
                (remove-hook 'next-error-hook #'evil-set-jump t)
                (remove-hook 'window-configuration-change-hook #'evil--jumps-window-configuration-hook t)))))

(defvar evil-mode)
(add-hook 'evil-mode-hook
          (lambda ()
            (when evil-mode
              (eval-after-load 'savehist
                '(progn
                   (defvar savehist-additional-variables)
                   (add-to-list 'savehist-additional-variables 'evil-jumps-history)
                   (let ((ring (make-ring evil-jumps-max-length)))
                     (cl-loop for jump in (reverse evil-jumps-history)
                              do (ring-insert ring jump))
                     (setf (evil-jumps-struct-ring (evil--jumps-get-current)) ring))

                   (add-hook 'savehist-save-hook #'evil--jumps-savehist-sync))))))

(provide 'evil-jumps)

;;; evil-jumps.el ends here
