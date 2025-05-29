(require "helix-file-watcher.scm")
(require "helix/editor.scm")
(require (prefix-in helix. "helix/commands.scm"))
(require "helix/misc.scm")
(require "helix/ext.scm")

(provide spawn-watcher)

;; Note, the below focus related functions are just vendored from mattwparas/helix-config

;; Last focused - will allow us to swap between the last view we were at
(define *last-focus* 'uninitialized)

;; Mark the last focused document, so that we can return to it
(define (mark-last-focused!)
  (let* ([focus (editor-focus)])
    (set! *last-focus* focus)
    focus))

(define (temporarily-switch-focus thunk)
  (define last-focused (mark-last-focused!))
  (define last-mode (editor-mode))
  (thunk)
  (editor-set-focus! last-focused)
  (editor-set-mode! last-mode))

(define (all-open-files)
  (map editor-document->path (editor-all-documents)))

(define (loop-events events)
  (define next-event (receive-event! events))
  (define paths (event-paths next-event))
  (define open-buffers (hx.block-on-task (lambda () (all-open-files))))
  ;; Lots of allocation
  (define intersection
    (hashset->list (hashset-intersection (list->hashset paths) (list->hashset open-buffers))))
  (for-each (lambda (x)
              ;; Enqueue each of these tasks to
              ;; be scheduled on the runtime
              (hx.with-context (lambda ()
                                 (temporarily-switch-focus (lambda ()
                                                             ;; Switch to the file, and reload it
                                                             (helix.open x)
                                                             (helix.reload))))))
            intersection)

  (loop-events events))

(define (spawn-watcher [path "."])
  (spawn-native-thread (lambda ()
                         (define events (watch-files path))
                         (loop-events events))))
