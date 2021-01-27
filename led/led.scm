#!/usr/bin/ol --run

;; led-eval : buff env exp -> buff' env'

(define *expected-owl-version* "0.2")

(if (not (equal? *owl-version* *expected-owl-version*))
   (begin
      (print-to stderr "Warning: expected owl version " *expected-owl-version* ", but running in " *owl-version* ". Expect turbulence.")
      (sleep 1000)))

(import
   (prefix (owl parse) get-)
   (only (owl parse) byte-stream->exp-stream fd->exp-stream)
   (only (owl readline) port->readline-byte-stream)
   (owl unicode)
   (only (owl sys) file? directory? kill sigkill)
   (owl terminal)
   (owl proof)
   (owl unicode)
   (only (led system) led-dir->list)
   (owl args)
   (only (led clock) clock-server)
   (only (led log) start-logger log)
   (only (led subprocess) start-repl communicate)
   (only (led parse) parse-runes get-command led-syntax-error-handler)
   (only (led screen) start-screen print-to clear-screen)
   (led buffer)
   (led env)
   (led eval)
   (led input)
   (led documentation)
   (only (owl syscall) link kill)
   (only (led ui) start-ui ui-put-yank ui-get-yank)
   (led render)
)

(define (bound lo x hi)
  (cond
    ((< x lo) lo)
    ((< hi x) hi)
    (else x)))

;; discard sender
(define (wait-message)
   (let ((envelope (wait-mail)))
      (ref envelope 2)))

;;; Visual operation

(define (next env b w h cx cy)
   (let ((m (check-mail)))
      (if m
         (begin
            ;(update-buffer-view b w h cx cy)
            (values (ref m 1) (ref m 2)))
         (let ((clients (get env 'clients null))
               (update (tuple 'update env b)))
            ;; send buffer and environment update to threads who requested for them
            (fold (λ (_ id) (mail id update)) 0 clients)
            (update-buffer-view env b w h cx cy)
            (let ((m (wait-mail)))
               (values
                  (ref m 1) (ref m 2)))))))

(define (lines-down-offset buff n)
   (let loop ((r (buffer-right buff)) (n n) (steps 0))
      (cond
         ((null? r)
            steps)
         ((eq? (car r) #\newline)
            (if (= n 0)
               (+ steps 1)
               (loop (cdr r) (- n 1) (+ steps 1))))
         (else
            (loop (cdr r) n (+ steps 1))))))

(define (lines-up-offset buff n)
   (let loop ((r (buffer-left buff)) (n n) (steps 0))
      (cond
         ((null? r)
            (* -1 steps))
         ((eq? (car r) #\newline)
            (if (= n 0)
               (* -1 steps)
               (loop (cdr r) (- n 1) (+ steps 1))))
         (else
            (loop (cdr r) n (+ steps 1))))))

(define (write-buffer! env b)
   (let ((bs (buffer->bytes b))
         (p  (get env 'path)))
      (if p
         (if (vector->file (list->vector bs) p)
            (put env 'message "written")
            (put env 'message "write failed"))
         (put env 'message "no path"))))

(define (closing-paren c)
   (cond
      ((eq? c #\() #\))
      ((eq? c #\[) #\])
      ((eq? c #\{) #\})
      (else #f)))

(define (opening-paren c)
   (cond
      ((eq? c #\)) #\()
      ((eq? c #\]) #\[)
      ((eq? c #\}) #\{)
      (else #f)))

(define (paren-hunt l closes len inc dec)
   (cond
      ((null? closes)
         len)
      ((null? l)
         #false)
      ((eq? (car l) (car closes))
         (paren-hunt (cdr l) (cdr closes) (+ len 1) inc dec))
      ((closing-paren (car l)) =>
         (lambda (cp)
            (paren-hunt (cdr l) (cons cp closes) (+ len 1) inc dec)))
      ((opening-paren (car l))
         #false)
      (else
         (paren-hunt (cdr l) closes (+ len 1) inc dec))))

(define (paren-hunter b)
   (b (λ (pos l r len line)
      (if (pair? r)
         (let ((cp (closing-paren (car r))))
            (if cp
               (paren-hunt (cdr r) (list cp) 1 40 41)
               #false))
         #false))))

(define (parent-expression b)
   (b (lambda (pos l r len line)
      (if (null? l)
         (values #false #false)
         (let loop ((l (cdr l)) (r (cons (car l) r)) (d 1))
            (cond
               ((null? r) (values #f #f))
               ((closing-paren (car r)) =>
                  (lambda (cp)
                     (let ((len (paren-hunt (cdr r) (list cp) 1 40 41)))
                        (if (and len (> len d))
                           (values (* -1 d) len)
                           (if (null? l)
                              (values #f #f)
                              (loop (cdr l) (cons (car l) r) (+ d 1)))))))
               ((null? l) (values #false #false))
               (else (loop (cdr l) (cons (car l) r) (+ d 1)))))))))

;; might make sense to require \n.
(define indent-after-newlines
   (string->regex "s/\\n/\\n   /g"))

(define (indent-selection env)
   (lambda (data)
      (ilist #\space #\space #\space
         (indent-after-newlines data))))

(define unindent-after-newlines
   (string->regex "s/\\n   /\n/g"))

(define unindent-start
   (string->regex "s/^   //"))

(define (unindent-selection env)
   (lambda (data)
      (unindent-start (unindent-after-newlines data))))

(define (add-mark env key pos len)
   (log "marking " (list->string (list key)) " as " pos " + " len)
   (let ((marks (get env 'marks)))
      (put env 'marks
         (put marks key (cons pos len)))))

(define (find-mark env key)
   (get (get env 'marks empty) key))

(define (maybe-car x)
   (if (pair? x)
      (car x)
      #f))

(define (next-line-same-pos b)
   (b
      (λ (pos l r len line)
         (lets ((lpos (or (distance-to l #\newline) (length l))) ;; maybe first line
                (rlen (distance-to r #\newline)))
            (if rlen ;; lines ahead
               (lets ((r (drop r (+ rlen 1))) ;; also newline
                      (rlen-next (or (distance-to r #\newline) (length r)))) ;; maybe last line
                  (cond
                     ((eq? rlen-next 0)
                        ;; next line is empty
                        (values (+ rlen 1) lpos))
                     ((<= rlen-next lpos)
                        ;; next line is short, need to move left
                        (values (+ rlen rlen-next)
                           (- lpos rlen-next -1)))
                     (else
                        (values (+ rlen 1 lpos) 0))))
               (values #f #f))))))

(define (prev-line-same-pos b)
   (b
      (λ (pos l r len line)
         (lets ((lpos (distance-to l #\newline)))
            (if lpos
               (lets
                  ((l (drop l (+ lpos 1)))
                   (next-len (or (distance-to l #\newline) (length l))))
                  (cond
                     ((eq? next-len 0)
                        ;; prev line is empty
                        (values (* -1 (+ lpos 1)) lpos))
                     ((<= next-len lpos)
                        (values (* -1 (+ lpos 2)) (- lpos next-len -1)))
                     (else
                        (values (* -1 (+ lpos 1 (- next-len lpos))) 0))))
               (values #f #f))))))

;; choose a nice vertical position for cursor given buffer
(define (nice-cx b w)
   (bound 1
      (+ 1 (buffer-line-offset b))
      w))

(define (first-line lst)
   (foldr
      (lambda (x tl)
         (if (eq? x #\newline)
            null
            (cons x tl)))
      '()
      lst))

(define (show-matching-paren env b)
   (lets
      ((b (seek-delta b -1)) ;; move back inside expression
       (back len (parent-expression b)))
      (if back
         (lets
            ((b (seek-delta b back))
             (b (buffer-selection-delta b len))
             (seln (get-selection b)))
            (set-status-text env
               (list->string
                  (take (first-line seln) 20))))
         (set-status-text env "?"))))

(define (selection-printable-length b)
      (fold
         (lambda (s c) (+ s (char-width c)))
         0
         (get-selection b)))

;; UI actions, to be bound to key bindings in env


(define (ui-unbound-key env mode b cx cy w h led)
   (led (set-status-text env "unbound key")
      mode b cx cy w h))

(define (ui-left env mode b cx cy w h led)
   (if (eq? (buffer-selection-length b) 0)
      ;; move forward regardless off selection
      (lets ((bp env (led-eval b env (tuple 'left))))
         (if (or (not bp) (eq? (buffer-char bp) #\newline))
            (led env mode b cx cy w h)
            (led env mode bp (max 1 (- cx (char-width (buffer-char bp)))) cy w h)))
      (led env mode
         (buffer-unselect b)
         cx cy w h)
            ))

(define (ui-down env mode b cx cy w h led)
   (lets ((delta nleft (next-line-same-pos b)))
      (if delta
         (let ((b (seek-delta b delta)))
            (led env mode b
               (nice-cx b w)
               (min (- h 1) (+ cy 1)) w h))
         (led env mode b cx cy w h))))

(define (ui-up env mode b cx cy w h led)
   (lets ((delta nleft (prev-line-same-pos b)))
      (if delta
         (let ((b (seek-delta b delta)))
            (led env mode b
               (nice-cx b w)
               (max 1 (- cy 1)) w h))
         (led env mode b cx cy w h))))

(define (ui-right-one-char env mode b cx cy w h led)
   (lets ((delta-cx (or (maybe char-width (buffer-char b)) 0))
          (bp (seek-delta b 1)))
      (if (or (not bp)
            (eq? (buffer-char b) #\newline))
         ;; no-op if out of line or data
         (led env mode b cx cy w h)
         (led env mode bp
            (if (< (+ cx delta-cx) w)
               (+ cx delta-cx)
               (nice-cx bp w))
            cy w h))))

(define (count-newlines lst)
   (fold
      (lambda (n x)
         (if (eq? x #\newline)
            (+ n 1)
            n))
      0 lst))

;; move by one char if nothing selected, otherwise to end of selection
(define (ui-right env mode b cx cy w h led)
   (let ((n (buffer-selection-length b)))
      (if (eq? n 0)
         ;; move forward regardless off selection
         (ui-right-one-char env mode b cx cy w h led)
         (lets
            ((seln (get-selection b))
             (b (seek-delta b n))
             (cx (nice-cx b w))
             (cy (min (- h 1) (+ cy (count-newlines seln)))))
            (led env mode b cx cy w h)))))

(define (ui-enter-insert-mode env mode b cx cy w h led)
   (lets
      ((old (get-selection b)) ;; data to be replaced by insert
       (env (put env 'insert-start (buffer-pos b)))
       (env (put env 'insert-original old))
       (b (buffer-delete b))) ;; remove old selection
      (led env 'insert b cx cy w h)))

(define (ui-yank env mode b cx cy w h led)
   (lets ((seln (get-selection b)))
      (ui-put-yank seln)
      (led env mode  b cx cy w h)))

(define (ui-next-match env mode b cx cy w h led)
   (let ((s (get env 'last-search)))
      (if s
         (lets ((p len (next-match b s)))
            (log "next search match is " p)
            (if p
               (lets ((b (seek-select b p len))
                      (lp (buffer-line-pos b)))
                  (led env mode b (if (>= lp w) 1 (+ lp 1)) 1 w h))
               (led env mode b cx cy w h)))
         (led env mode b cx cy w h))))

(define (ui-select-rest-of-line env mode b cx cy w h led)
   (led env mode
      (select-rest-of-line b #f)
      cx cy w h))

(define (ui-line-end env mode b cx cy w h led)
   (lets ((nforw (buffer-line-end-pos b))
          (b (seek-delta b nforw)))
      (led env mode b
         (bound 1 (+ cx nforw) w)
         cy w h)))

(define (ui-select-word env mode b cx cy w h led)
   (lets ((word-length (buffer-next-word-length b)))
      (led env mode
         (buffer-selection-delta b word-length)
         cx cy w h)))

(define (ui-add-mark env mode b cx cy w h led)
   (log "adding mark")
   (lets ((envelope (accept-mail (lambda (x) (eq? (ref (ref x 2) 1) 'key)))))
      (log "marking to " (ref envelope 2))
      (led
         (add-mark env (ref (ref envelope 2) 2) (buffer-pos b) (buffer-selection-length b))
         mode b cx cy w h)))

(define (ui-go-to-mark env mode b cx cy w h led)
   (lets
      ((envelope (accept-mail (lambda (x) (eq? (ref (ref x 2) 1) 'key))))
       (from msg envelope)
       (_ key msg)
       (location (find-mark env key)))
      (if location
         (lets
            ((bp (seek-select b (car location) (cdr location))))
            (if bp
               (led env mode bp
                  (nice-cx bp w)
                  1 w h)
               (led env mode b cx cy w h)))
         (led env mode b cx cy w h))))

(define (ui-select-current-line env mode b cx cy w h led)
   (if (= 0 (buffer-selection-length b))
      (led env mode (select-line b (buffer-line b)) 1 cy w h)
      (led env mode b cx cy w h)))

(define (ui-select-next-char env mode b cx cy w h led)
   (led env mode (buffer-selection-delta b +1) cx cy w h))

(define (ui-unselect-last-char env mode b cx cy w h led)
   (led env mode (buffer-selection-delta b -1) cx cy w h))


;; as with end of line, maybe instead select?
(define (ui-go-to-start-of-line env mode b cx cy w h led)
   (led env mode
      (seek-start-of-line b)
      1 cy w h))

(define (ui-select-start-of-line env mode b cx cy w h led)
   (lets ((pos (buffer-pos b))
          (b (seek-start-of-line b))
          (len (- pos (buffer-pos b))))
      (led env mode
         (set-selection-length b len)
         1 cy w h)))

(define (ui-delete env mode b cx cy w h led)
   (ui-put-yank (get-selection b))
   (lets ((buff env (led-eval b env (tuple 'delete))))
      (led env mode buff cx cy w h)))

(define (ui-paste env mode b cx cy w h led)
   (let ((data (ui-get-yank)))
      (if data
         (lets ((buff env (led-eval b env (tuple 'replace data))))
            (led env mode buff cx cy w h))
         (led
            (put env 'status-message "nothing yanked")
            mode b cx cy w h))))

;; y at middle of screen would be more readable
(define (ui-undo env mode b cx cy w h led)
   (lets ((b env (led-eval b env (tuple 'undo))))
      (led env mode b
         (nice-cx b w)
         1 w h)))

(define (ui-redo env mode b cx cy w h led)
   (lets ((b env (led-eval b env (tuple 'redo))))
      (led env mode b
         (nice-cx b w)
         1 w h)))

(define (ui-indent env mode b cx cy w h led)
   (lets ((buff env (led-eval b env (tuple 'replace ((indent-selection env) (get-selection b))))))
      (led env mode buff cx cy w h)))

(define (ui-unindent env mode b cx cy w h led)
   (lets ((buff env (led-eval b env (tuple 'replace ((unindent-selection env) (get-selection b))))))
      (led env mode buff cx cy w h)))

(define (ui-select-down env mode b cx cy w h led)
   (lets
      ((pos (buffer-pos b))
       (len (buffer-selection-length b))
       (bx  (seek b (+ pos len)))
       (delta nleft (next-line-same-pos bx)))
      (if delta
         (led env mode (buffer-selection-delta b delta) cx cy w h)
         (led env mode b cx cy w h))))

(define (ui-find-matching-paren env mode b cx cy w h led)
   (lets ((delta (paren-hunter b)))
      (if (and delta (> delta 0))
         (led env mode
            (buffer-selection-delta (buffer-unselect b) delta)
            cx cy w h)
         (led env mode b cx cy w h))))

(define (ui-select-parent-expression env mode b cx cy w h led)
   (lets ((back len (parent-expression b))
          (old-line (buffer-line b)))
      (if back
         (lets
            ((b (seek-delta b back))
             (new-line (buffer-line b)))
            (led env mode
               (buffer-selection-delta (buffer-unselect b) len)
               (nice-cx b w)
               (bound 1 (- cy (- old-line new-line)) h)
               w h))
         (led env mode b cx cy w h))))

(define (ui-toggle-line-numbers env mode b cx cy w h led)
   (led (put env 'line-numbers (not (get env 'line-numbers #false)))
      mode b cx cy w h))

(define (ui-close-buffer-if-saved env mode b cx cy w h led)
   (lets ((bp ep (led-eval b env (tuple 'quit #f))))
      ;; only exits on failure
      (led
         (set-status-text env "Buffer has unsaved content.")
         mode b cx cy w h)))

;(define (ui-write-buffer env mode b cx cy w h led)
;   (lets ((b (buffer-select-current-word b))
;          (seln (get-selection b))
;          (lp (buffer-line-pos b)))
;      (led env mode b
;         (min w (max 1 (+ 1 lp))) cy w h)))

(define (ui-start-lex-command env mode b cx cy w h led)
   (mail (get env 'status-thread-id) (tuple 'start-command #\:))
   (led (clear-status-text env) 'enter-command b cx cy w h))

(define (ui-start-search env mode b cx cy w h led)
   (mail (get env 'status-thread-id) (tuple 'start-command #\/))
   (led (clear-status-text env) 'enter-command b cx cy w h))

(define *default-command-mode-key-bindings*
   (ff
      #\N ui-toggle-line-numbers
      #\Q ui-close-buffer-if-saved
      #\h ui-left
      #\l ui-right
      #\j ui-down
      #\k ui-up
      #\i ui-enter-insert-mode
      #\y ui-yank
      #\n ui-next-match
      #\$ ui-select-rest-of-line
      #\w ui-select-word
      #\m ui-add-mark
      #\' ui-go-to-mark
      #\. ui-select-current-line
      #\L ui-select-next-char
      #\H ui-unselect-last-char
      #\0 ui-select-start-of-line
      #\d ui-delete
      #\p ui-paste
      #\u ui-undo
      #\r ui-redo
      #\J ui-select-down
      #\> ui-indent
      #\< ui-unindent
      #\% ui-find-matching-paren
      #\e ui-select-parent-expression
      #\: ui-start-lex-command
      #\/ ui-start-search
      ))

(define (ui-page-down env mode b cx cy w h led)
   (led env mode
      (seek-delta b (lines-down-offset b (max 1 (- h 2))))
      1 cy w h))

(define (ui-page-up env mode b cx cy w h led)
   (let ((b (seek-delta b (lines-up-offset b (max 1 (- h 1))))))
      (led env mode b 1 (min cy (buffer-line b)) w h)))

(define (ui-repaint env mode b cx cy w h led)
   (mail 'ui (tuple 'clear)) ;; clear screen
   (led
      (del env 'status-message)
      mode b cx cy w h))

(define (ui-clean-buffer env mode b cx cy w h led)
   (lets ((exp
            (tuple 'seq
               (tuple 'select 'everything)
               (tuple 'call "clean")))
          (bp ep (led-eval b env exp)))
      (if bp
         (led ep mode bp 1 1 w h)
         (led (set-status-text env "Nothing to clean") mode b cx cy w h))))

(define (ui-format-paragraphs env mode b cx cy w h led)
   (lets ((exp (tuple 'call "fmt"))
          (bp ep (led-eval b env exp)))
      (if bp
         (led ep mode bp cx cy w h)
         (led (set-status-text env "nothing happened") mode b cx cy w h))))

(define (ui-save-buffer env mode b cx cy w h led)
   (let ((pathp (get env 'path)))
      (if pathp
         (lets ((buffp envp (led-eval b env (tuple 'write-buffer pathp))))
            (if buffp
               (led envp mode buffp cx cy w h)
               (led env mode b cx cy w h)))
         (led
            (set-status-text env
               "No path yet.")
            mode b cx cy w h))))

(define (ui-send-to-subprocess env mode b cx cy w h led)
   (let ((proc (get env 'subprocess)))
      (log " => sending to " proc)
      (if proc
         (lets ((resp (communicate proc (get-selection b)))
                (b (buffer-after-dot b))
                (data (or (utf8-decode (or resp null)) null))
                (delta (tuple (buffer-pos b) null data)))
            (log " => " data)
            (led
               (if (null? data)
                  (set-status-text env "No data received from subprocess.")
                  (push-undo env delta))
               mode
               (buffer-append b data)
               cx cy w h))
         (begin
            (log " => no subprocess")
            (led env mode b cx cy w h)))))

(define (ui-do env mode b cx cy w h led)
   (lets
      ((bp (if (= 0 (buffer-selection-length b)) (buffer-select-current-word b) b)) ;; fixme - cursor move
       (cx (nice-cx bp w))
       (s (list->string (get-selection bp))))
      (cond
         ((file? s)
            (mail 'ui (tuple 'open s env)) ;; <- actually we want a subset, but whole env for now
            (led env mode bp cx cy w h))
         ((directory? s)
            (lets
               ((fs (or (led-dir->list s) null))
                (contents
                   (foldr
                       (lambda (path tail) (render path (if (null? tail) tail (cons 10 tail))))
                       null fs))
                (buff env (led-eval bp env (tuple 'replace contents))))
               (led env mode buff cx cy w h)))
         (else
            (led env mode bp cx cy w h)))))

(define *default-command-mode-control-key-bindings*
   (ff
      'f ui-page-down
      'b ui-page-up
      'l ui-repaint
      'e ui-clean-buffer
      'j ui-format-paragraphs
      'w ui-save-buffer
      'x ui-send-to-subprocess
      'm ui-do))

;; convert all actions to (led eval)ed commands later
(define (led env mode b cx cy w h)
   ;(print (list 'buffer-window b cx cy w h))
   (lets ((from msg (next env b w h cx cy))
          (op (ref msg 1)))
      (log "led: " mode " <- " msg " from " from)
      (cond
         ((eq? op 'terminal-size)
            (lets ((_ w h msg))
               (for-each
                  (λ (cli) (mail cli msg))
                  (get env 'clients null))
               (clear-screen)
               (update-buffer-view env b w h (min cx w) (min cy h))
               (led env mode b (min cx w) (min cy h) w h)))
         ((eq? op 'status-line)
            (led
               (put env 'status-line msg) ;; #(status-line <bytes> <cursor-x>)
               mode b cx cy w h))
         ((eq? op 'keep-me-posted)
            (led (put env 'clients (cons from (get env 'clients null)))
               mode b cx cy w h))
         ((eq? op 'command-entered)
            (lets
               ((runes (ref msg 2)))
               (cond
                  ((eq? (maybe-car runes) #\:)
                     (lets ((buff env (led-eval-runes b env (cdr runes))))
                        (led env 'command   ;; env always there, may have error message
                           (or buff b)      ;; in case command fails
                           (nice-cx buff w) ;; buffer may change from underneath
                           (min cy (buffer-line buff)) ;; ditto
                           w h)))
                  ((eq? (maybe-car runes) #\/)
                     (log "saving last search " (cdr runes))
                     (let ((env (put env 'last-search (cdr runes))))
                        (led env 'command b cx cy w h)))
                  (else
                     (log "wat command " (runes->string runes))
                     (led env 'command b cx cy w h)))))
         ((eq? op 'command-aborted)
            ;; search or colon command was aborted, resume command mode
            (led env 'command b cx cy w h))
         ((eq? op 'command-updated)
            (let ((runes (ref msg 2)))
               (if (eq? (car runes) #\/) ;; this is a search
                  (let ((pos (first-match b (cdr runes))))
                     (if pos
                         (lets ((b (seek-select b pos (length (cdr runes))))
                                (lp (buffer-line-pos b)))
                            (led env mode b (if (>= lp w) 1 (+ lp 1)) 1 w h))
                         (led env mode b cx cy w h)))
                   (led env mode b cx cy w h))))
         ((eq? mode 'command)
            (tuple-case msg
               ((ctrl k)
                  (let ((handler (get (get env 'command-mode-control-key-bindings empty) k ui-unbound-key)))
                     (handler env mode b cx cy w h led)))
               ((key x)
                  ((get (get env 'command-mode-key-bindings empty) x ui-unbound-key)
                     env mode b cx cy w h led))
               ((esc)
                  (led env mode (buffer-unselect b) cx cy w h))
               ((enter) ;; remove after owl 0.2.1
                  (ui-do env mode b cx cy w h led))
               (else
                  (led env mode b cx cy w h))))
         ((eq? mode 'insert)
            (tuple-case msg
               ((key x)
                  (lets
                     ((b (buffer-append-noselect b (list x))))
                     (if (eq? x 41) ;; closing paren
                        (show-matching-paren env b))
                     (led
                        (if (eq? x 41)
                           (show-matching-paren env b)
                           env)
                        'insert b (min w (+ cx (char-width x))) cy w h)))
               ((refresh)
                  (led env 'insert b cx cy w h))
               ((esc)
                  (lets ((start (get env 'insert-start 0))
                         (end (buffer-pos b))
                         (delta
                            (tuple start
                               (get env 'insert-original null)
                               (buffer-get-range b start end))))
                  (led
                     (push-undo env delta)
                     'command b cx cy w h)))
               ((ctrl k)
                  (cond
                     ;((eq? k 'c)
                     ;   (led env 'command b cx cy w h))
                     ((eq? k 'm) ;; enter
                        (lets
                           ((i (if (get env 'autoindent) (buffer-line-indent b) null))
                            (b (buffer-append-noselect b (cons #\newline i))))
                           (led env 'insert b
                              (bound 1 (+ (length i) 1) w)
                              (min (- h 1) (+ cy 1)) w h))) ;; -1 for status line
                     ((eq? k 'i) ;; tab
                        (lets ((b (buffer-append-noselect b (list #\space #\space #\space))))
                           (led env mode b (min w (+ cx 3)) cy w h)))
                     ((eq? k 'w)
                        (let ((pathp (get env 'path)))
                           (if pathp
                              (lets ((buffp envp (led-eval b env (tuple 'write-buffer pathp))))
                                 (if buffp
                                    (led envp mode buffp cx cy w h)
                                    (led env mode b cx cy w h)))
                              (led
                                 (set-status-text env
                                    "No path yet.")
                                 mode b cx cy w h))))
                     (else
                        (led env mode b cx cy w h))))
               ((tab) ;; remove after owl 0.2.1
                  (lets ((b (buffer-append-noselect b (list #\space #\space #\space))))
                     (led env mode b (min w (+ cx 3)) cy w h)))
               ((enter) ;; remove after owl 0.2.1
                  (lets
                     ((i (if (get env 'autoindent) (buffer-line-indent b) null))
                      (b (buffer-append-noselect b (cons #\newline i))))
                     (led env 'insert b
                        (bound 1 (+ (length i) 1) w)
                        (min (- h 1) (+ cy 1)) w h))) ;; -1 for status line
               ((arrow dir)
                  (cond
                     ((eq? dir 'up)
                        (led env 'insert b cx (max 1 (- cy 1)) w h))
                     ((eq? dir 'down)
                        (led env 'insert b cx (min (+ cy 1) h) w h))
                     ((eq? dir 'left)
                        (led env 'insert b (max 1 (- cx 1)) cy w h))
                     (else
                        (led env 'insert b (min w (+ cx 1)) cy w h))))
               ((backspace)
                  (if (> (buffer-pos b) (get env 'insert-start 0)) ;; no backspacing out of area to be changed
                     (lets
                        ((p (buffer-pos b))
                         (lp (buffer-line-pos b))
                         (b (select b (- p 1) p))
                         (b (buffer-delete b)))
                        (if (eq? lp 0)
                           (led env mode b
                              (min w (+ 1 (buffer-line-pos b)))
                              (max (- cy 1) 1) w h)
                           (led env mode b (max 1 (- cx 1)) cy w h)))
                     (led env mode b cx cy w h)))
               (else is foo
                  (mail 'ui
                     (tuple 'print-to 1 (+ h 1) (str "watx " foo)))
                  (led env 'insert b cx cy w h))))
         ((eq? mode 'enter-command)
            ; colon prefixed command
            ; send keys to the status bar
            (log "Forwarding command " msg " to status thread " (get env 'status-thread-id))
            (mail (get env 'status-thread-id) msg)
            (led env mode b cx cy w h))
         (else
            (led env 'command b cx cy w h)))))


(define (maybe-put ff k v)
   (if v (put ff k v) ff))


;; (help), etc
(define (list-buffer x)
   (log "List buffer " x)
   (if (eq? (car x) 'help)
      (begin
         (log "Opening help buffer")
         (help-buffer x))
      (begin
         (log "Unknown list")
         #f)))

(define default-led-opener
   (lambda (path env)
      (log "UI: opening buffer " path)
      (lets
         ((id (or path (list '*scratch*)))
          (status-thread-id (cons id 'status-line)))
         (thread id
            (led
               (put (empty-led-env env id (if (string? path) path #f))
                  'status-thread-id status-thread-id)
               'command
               (cond
                  ((string? path)
                     (or
                        (file-buffer path) ;; <- grab encoding to env later
                        (dir-buffer path)
                        (string-buffer "Tabula rasa")))
                  ((pair? path)
                     (list-buffer path)
                     )
                  (else
                     (string-buffer "")))
               1 1 10 10)) ;; <- ui sends terminal size as first message
         (link id)
         (link
            (thread status-thread-id
               (start-status-line id 80)))
         id)))



(define version-str "led v0.2a")

(define usage-text "led [args] [file-or-directory] ...")

(define command-line-rules
  (cl-rules
    `((help "-h" "--help" comment "show this thing")
      (version "-v" "--version" comment "show program version")
      (log "-L" "--log" has-arg comment "debug log file")
      (repl "-r" "--repl" comment "line-based repl")
      ;(config "-c" "--config" has-arg comment "config file (default $HOME/.ledrc)")
      )))


(define *default-environment*
   (pipe empty
      (put 'command-mode-key-bindings *default-command-mode-key-bindings*)
      (put 'command-mode-control-key-bindings
         *default-command-mode-control-key-bindings*)
      ))

(define (start-led-threads dict args)
   (cond
      ((get dict 'help)
         (print usage-text)
         (print (format-rules command-line-rules))
         0)
      ((get dict 'version)
         (print version-str)
         0)
      ((get dict 'repl)
         (link (start-logger (get dict 'log)))
         (led-repl (string-buffer "")
            (empty-led-env *default-environment* #f  #f)))
      (else
         (lets ((input (terminal-input (put empty 'eof-exit? #f)))
                (x y ll (get-terminal-size input)))
            (link (start-logger (get dict 'log)))
            (log "Terminal dimensions " (cons x y))
            (start-screen x y)
            (log "Screen running")
            ;(clear-screen)
            (start-input-terminal (start-ui) ll)
            (log "Input terminal and UI running")
            (thread 'clock (clock-server))
            (mail 'ui (tuple 'add-opener default-led-opener))
            (mail 'ui (tuple 'terminal-size x y))
            (for-each
               (lambda (path)
                  (mail 'ui (tuple 'open path *default-environment*)))
               (if (null? args)
                  (list #false)
                  args))
            (let loop ()
               (let ((mail (wait-mail)))
                  ;(print mail)
                  (log "CRASH " mail)
                  ;(write-bytes stderr (string->bytes (str mail "\n")))
                  ;(halt 1)
                  ;(loop)
                  ))))))

(define (main args)
   (process-arguments (cdr args)
      command-line-rules
      usage-text
      start-led-threads))

main



