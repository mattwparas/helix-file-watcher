(require "helix-file-watcher.scm")
(require "helix/editor.scm")
(require (prefix-in helix. "helix/commands.scm"))
(require "helix/misc.scm")
(require "helix/ext.scm")
(require "helix/static.scm")
(require-builtin steel/time)

(provide spawn-watcher)

(define (all-open-files)
  (map editor-document->path (editor-all-documents)))

(define (try-canonicalize-path x)
  (with-handler (lambda (err)
                  (displayln "Failed canonicalizing path: " x err)
                  #f)
                (canonicalize-path x)))

(define (open-file-if-not-already-open x)
  (unless (equal? x (~> (editor-focus) editor->doc-id editor-document->path))
    (helix.open x)))

(define (temporarily-switch-focus thunk)
  (define last-focused (editor-focus))
  (define last-mode (editor-mode))
  (thunk)
  (editor-set-focus! last-focused)
  (editor-set-mode! last-mode))

(define (open-or-switch-focus document-id)
  (define maybe-view-id? (editor-doc-in-view? document-id))
  (if maybe-view-id?
      (editor-set-focus! maybe-view-id?)
      (editor-switch! document-id)))

(define (maybe-reload x [thunk #f])
  (define helix-doc-last-saved (~> (editor-focus) editor->doc-id editor-document-last-saved))
  ;; If the helix las
  (define file-last-modified (fs-metadata-modified (file-metadata x)))
  (define now (system-time/now))

  ;; Racing helix... no good
  (when (system-time<? helix-doc-last-saved file-last-modified)
    (helix.reload)

    (when thunk
      (thunk))))

(define (path->doc-id path)
  (define paths
    (filter (lambda (doc-id) (equal? (editor-document->path doc-id) path)) (editor-all-documents)))

  (if (= (length paths) 1)
      (car paths)
      #f))

(define (loop-events events)
  (define next-event (receive-event! events))
  (with-handler
   (lambda (err)
     (displayln err)
     (loop-events events))
   (define paths (map try-canonicalize-path (event-paths next-event)))
   (define open-buffers (map try-canonicalize-path (hx.block-on-task (lambda () (all-open-files)))))
   ;; Lots of allocation!
   (define intersection
     (filter (lambda (x) x)
             (hashset->list (hashset-intersection (list->hashset paths)
                                                  (list->hashset open-buffers)))))
   (unless (empty? intersection)
     (hx.with-context
      (lambda ()
        ;; Give helix like, 5 seconds to make an edit before deciding to update
        ;; Enqueue a callback with a delay, without blocking the thread.
        (enqueue-thread-local-callback-with-delay
         2000
         (lambda ()
           ;; Save where we are, jump in to each of these, call the function.
           (temporarily-switch-focus
            (lambda ()
              (for-each (lambda (x)
                          ;; Switch to the file, and reload it only if the write time isn't the same
                          ;; as it is for helix
                          (if (equal? x (~> (editor-focus) editor->doc-id editor-document->path))
                              (maybe-reload x)
                              (begin
                                (open-or-switch-focus (path->doc-id x))
                                (maybe-reload x))))
                        ; ))
                        intersection))))))))
   (loop-events events)))

(define (spawn-watcher [path "."])
  (spawn-native-thread (lambda ()
                         (define events (watch-files path))
                         (loop-events events))))
