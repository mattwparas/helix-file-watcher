(require "helix-file-watcher.scm")
(require "helix/editor.scm")
(require (prefix-in helix. "helix/commands.scm"))
(require "helix/misc.scm")
(require "helix/ext.scm")
(require "helix/static.scm")
(require-builtin steel/time)

(provide spawn-watcher)

(define _watcher-pair (make-empty-watcher))
(define watch-handle (list-ref _watcher-pair 0))
(define event-handle (list-ref _watcher-pair 1))

(define (all-open-files)
  (~>> (editor-all-documents)
       (map editor-document->path)
       (filter id)
       (map try-canonicalize-path)
       (filter id)))

(define (try-canonicalize-path x)
  (with-handler (lambda (err)
                  (log::info! (to-string "Failed canonicalizing path: " x err))
                  #f)
                (canonicalize-path x)))

(define (path->doc-id path)
  (define paths
    (filter (lambda (doc-id) (equal? (editor-document->path doc-id) path)) (editor-all-documents)))

  (if (= (length paths) 1) (car paths) #f))

;; reload file only if the write time isn't the same as it is for helix
(define (maybe-reload x [thunk #f])
  (define doc-id (path->doc-id x))
  (when doc-id
    (define helix-doc-last-saved (editor-document-last-saved doc-id))
    (define file-last-modified (fs-metadata-modified (file-metadata x)))
    ;; Racing helix... no good
    (when (and helix-doc-last-saved (system-time<? helix-doc-last-saved file-last-modified))
      (log::info! (to-string "reloading file: " x))
      (editor-document-reload doc-id)
      (when thunk
        (thunk)))))

(define *min-poll-ms* 50)
(define *max-poll-ms* 500)

(define (poll-paths)
  (with-handler (lambda (err)
                  (log::info! (to-string "file watcher: event channel closed: " err))
                  #f)
                (drain-event-paths! event-handle)))

(define (handle-changed-paths paths delay-ms)
  (with-handler
   (lambda (err) (log::info! (to-string "file watcher: " err)))
   (define changed (filter id (map try-canonicalize-path paths)))
   (define open-buffers (hx.block-on-task (lambda () (all-open-files))))
   ;; Lots of allocation!
   (define intersection
     (hashset->list (hashset-intersection (list->hashset changed) (list->hashset open-buffers))))
   (unless (empty? intersection)
     (hx.with-context (lambda ()
                        ;; Give helix like, 5 seconds to make an edit before deciding to update
                        ;; Enqueue a callback with a delay, without blocking the thread.
                        (enqueue-thread-local-callback-with-delay
                         delay-ms
                         (lambda () (for-each maybe-reload intersection))))))))

(define (loop-events delay-ms)
  (let loop ([poll-ms *min-poll-ms*])
    (define paths (poll-paths))
    (cond
      [(not paths) (log::info! "file watcher: shutting down event loop")]
      [(empty? paths)
       (time/sleep-ms poll-ms)
       (loop (min (* 2 poll-ms) *max-poll-ms*))]
      [else
       (handle-changed-paths paths delay-ms)
       (loop *min-poll-ms*)])))

(define (set-watch-files paths)
  (for-each (lambda (x) (watch-file! watch-handle x)) paths))

(define *started* #f)

(register-hook! 'document-opened
                (lambda (_)
                  (when *started*
                    (set-watch-files (all-open-files)))))

;;@doc
;; Spawn a file watcher which will reload
(define (spawn-watcher [delay-ms 2000])
  (log::info! (to-string "setting initial watched files"))
  (set-watch-files (all-open-files))
  (spawn-native-thread (lambda ()
                         (set! *started* #t)
                         (log::info! "starting event loop")
                         (loop-events delay-ms))))
