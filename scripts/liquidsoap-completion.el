;; Inspired of
;; http://sixty-north.com/blog/writing-the-simplest-emacs-company-mode-backend
;; http://sixty-north.com/blog/a-more-full-featured-company-mode-backend.html

(require 'cl-lib)
(require 'company)

(defconst liquidsoap-completions
  '(
    #("source.metadata" 0 1 (:type "(string) -> [string]" :description "Show metadata."))
    #("source.duration" 0 1 (:type "(string) -> float" :description "Duration of the source."))
    #("playlist" 0 1 (:type "(string) -> source" :description "Stream a playlist."))
    )
)

(defun liquidsoap-annotation (s)
  (format " : %s" (get-text-property 0 :type s))
)

(defun liquidsoap-meta (s)
  (get-text-property 0 :description s)
)

(defun company-liquidsoap-backend (command &optional arg &rest ignored)
  (interactive (list 'interactive))

  (cl-case command
    (interactive (company-begin-backend 'company-liquidsoap-backend))
    (prefix (and (eq major-mode 'liquidsoap-mode) (company-grab-symbol)))
    (candidates
     (cl-remove-if-not
       (lambda (c) (string-prefix-p arg c))
       liquidsoap-completions))
    (annotation (liquidsoap-annotation arg))
    (meta (liquidsoap-meta arg))
  )
)

(add-to-list 'company-backends 'company-liquidsoap-backend)

(provide 'liquidsoap-completion)
