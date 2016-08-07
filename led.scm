#!/usr/bin/ol --run

; id€ntitéèttı = λÅ.(Å Å)

(import
  (owl terminal)
  (only (owl unicode) encode-point)
  (owl args))

(define version-str "led v0.1a")

;;; Temporary logging

(define logfd 
   (open-output-file "led.log"))

(define (log . what)
   (print-to logfd what))



;;; Movement and insert mode edit operation

(define (buffer up down left right x y w h off meta)
   (tuple up down left right x y w h off meta))

(define (make-empty-state w h meta)
	(buffer null null null null 1 1 w h (cons 0 0) meta))

(define (buffer-meta buff)
  (ref buff 10))

(define (set-buffer-meta buff meta)
  (set buff 10 meta))

(define (buffer-x buff) (ref buff 5))
(define (buffer-y buff) (ref buff 6))

(define (make-file-state w h path meta)
  (let ((data (map string->list (force-ll (lines (open-input-file path))))))
    (if (pair? data)
      (buffer null (cdr data) null (car data) 1 1 w h (cons 0 0) 
        (put meta 'path path))
      (error "could not open " path))))

(define (screen-width buff) (ref buff 7))

(define (screen-height buff) (ref buff 8))

(define (take-printable line n)
  (cond
    ((eq? n 0) null)
    ((pair? line)
      (lets ((x line line))
        (cond
          ((eq? (type x) type-fix+)
            ;; a printable unicode code point
            (if (eq? 0 (fxband x #x80))
              ;; a printable ascii range thingie (usual suspect)
              (cons x (take-printable line (- n 1)))
              (encode-point x
                (take-printable line (- n 1)))))
          (else
            (error "take-printable: what is " x)))))
    (else
      null)))
            

(define (draw-lines-at-offset tl w dx y dy end lines)
   (cond
      ((null? lines) tl)
      ((eq? y end) tl)
      (else
         (let ((these (drop (car lines) dx)))
            (tio*
               (set-cursor 1 y)
               (clear-line-right)
               (raw (take-printable these w))
               (draw-lines-at-offset w dx (+ y dy) dy end (cdr lines))
               tl)))))
                  
(define (update-screen buff)
   (lets 
      ((u d l r x y w h off meta buff)
       (this (append (reverse l) r)))
      (tio
          (clear-screen)
          (draw-lines-at-offset w (car off) y -1 0 (cons this u))
          (draw-lines-at-offset w (car off) (+ y 1) +1 (+ h 1) d)
          (set-cursor x y))))

(define (scroll-right buff)
   (lets 
      ((u d l r x y w h off meta buff)
       (dx dy off)
       (step (* 2 (div w 3)))
       (buff (buffer u d l r (- x step) y w h (cons (+ dx step) dy) meta)))
      (values buff (update-screen buff))))

(define (scroll-left buff)
   (lets 
      ((u d l r x y w h off meta buff)
       (dx dy off))
      (if (eq? dx 1)
        (values buff null)
        (lets
          ((step (min dx (* 2 (div w 3))))
           (buff (buffer u d l r (+ x step) y w h (cons (- dx step) dy) meta)))
          (values buff (update-screen buff))))))

(define (scroll-down buff)
   (lets 
    ((u d l r x y w h off meta buff)
     (step (+ 1 (* 2 (div h 3))))
     (dx dy off)
     (buff 
      (buffer u d l r x (- y step) w h (cons dx (+ dy step)) meta)))
    (values buff
      (update-screen buff))))

(define (scroll-up buff)
   (lets 
    ((u d l r x y w h off meta buff)
     (dx dy off)
     (step (min dy (+ 1 (* 2 (div h 3)))))
     (buff 
      (buffer u d l r x (+ y step) w h (cons dx (- dy step)) meta)))
    (values buff
      (update-screen buff))))

;; scroll window all the way left, if necessary
(define (reset-left buff)
   (lets 
      ((u d l r x y w h off meta buff)
       (dx dy off))
;      (if (eq? dx 1) (values buff null) ...)
         (let ((r (append (reverse l) r)))
            (values
               (buffer u d null r 1 y w h (cons 0 dy) meta)
               (tio
                  (draw-lines-at-offset w 0 (- y 1) -1 0 u)
                  (draw-lines-at-offset w 0 (+ y 1) +1 (+ h 1) d)
                  (set-cursor 1 y)
                  (clear-line-right)
                  (raw (take-printable r w))
                  (set-cursor 1 y))))))

(define (log-buff buff)
  (lets
    ((u d l r x y w h off meta buff))
    (log "log: cursor at " (cons x y) " at offset " off ", line pos " (+ (car off) (- x 1)))))
        

(define (insert-handle-key buff k)
   (lets ((u d l r x y w h off meta buff))
      (if (eq? x w)
         (lets
            ((buff scroll-tio (scroll-right buff))
             (buff insert-tio (insert-handle-key buff k)))
            (values buff
               (append scroll-tio insert-tio)))
         (begin
            (log "insert of key " k " at " (cons x y))
            (values
               (buffer u d (cons k l) r (+ x 1) y w h off meta)
               (encode-point k
                  (if (null? r)
                     null
                     (tio
                        (clear-line-right)
                        (cursor-save)
                        (raw (take-printable r (- w (+ x 1))))
                        (cursor-restore)))))))))

(define (insert-backspace buff)
   (lets ((u d l r x y w h off meta buff))
      (cond
         ((null? l)
            ;; no-op (could also backspace to line above)
            (values buff null))
         ((eq? x 1)
            (lets 
               ((buff scroll-tio (scroll-left buff))
                (buff bs-tio     (insert-backspace buff)))
               (values buff
                  (append scroll-tio bs-tio))))
         (else
            (values
               (buffer u d (cdr l) r (- x 1) y w h off meta)
               (tio
                  (cursor-left 1)
                  (clear-line-right)
                  (cursor-save)
                  (raw (take-printable r (- w x)))
                  (cursor-restore)))))))

;; (a b c d ... n) 3 → (c b a) (d... n)
(define (line-seek line pos)
  (let loop ((line line) (pos pos) (l null))
    (cond
      ((eq? pos 0)
        (values l line))
      ((null? line)
        (error "empty line at line-seek: " pos))
      (else
        (loop (cdr line) (- pos 1) (cons (car line) l))))))

;; move line down within the same screen preserving cursor position if possible
(define (line-down buff)
   (lets ((u d l r x y w h off meta buff)
          (dx dy off)
          (_ (log "line-down starting from " (cons x y)))
          (line (append (reverse l) r))
          (u (cons line u))
          (y (+ y 1))
          (line d (uncons d null))
          (x (min x (+ 1 (- (length line) (car off)))))
          (line-pos (+ (- x 1) (car off)))
          (l r (line-seek line line-pos)))
        (log "line-down went to (x . y) " (cons x y))
        (log "next line length is " (length line) ", x=" x ", dx=" (car off) ", l='" (list->string l) "', r='" (list->string r) "'")
        (values
          (buffer u d l r x y w h off meta)
          x y)))

;; move line up within the same screen preserving cursor position if possible
(define (line-up buff)
   (lets ((u d l r x y w h off meta buff)
          (dx dy off)
          (line (append (reverse l) r))
          (d (cons line d))
          (y (- y 1))
          (line u (uncons u null))
          (x (min x (+ 1 (- (length line) (car off)))))
          (line-pos (+ (- x 1) (car off)))
          (l r (line-seek line line-pos)))
        (log "line-up went to (x . y) " (cons x y))
        (log "next line length is " (length line) ", x=" x ", dx=" (car off) ", l='" (list->string l) "', r='" (list->string r) "'")
        (values
          (buffer u d l r x y w h off meta)
          x y)))

(define (move-arrow buff dir)
   (lets ((u d l r x y w h off meta buff))
      (log "arrow " dir " from " (cons x y))
      (cond
         ((eq? dir 'up)
            (cond
               ((null? u)
                  (values buff null))
               ((eq? y 1)
                  (lets
                    ((buff tio-scroll (scroll-up buff))
                     (buff tio-move (move-arrow buff dir)))
                    (values buff
                      (append tio-scroll tio-move))))
              ((not (eq? 0 (car off))) ;; there is x-offset
                (let ((next-len (length (car u))))
                  (if (< next-len (car off)) ;; next line start not visible
                    (lets ;; dummy version
                      ((buff tio (move-arrow buff 'left))
                       (buff tio-this (move-arrow buff dir)))
                      (values buff (append tio tio-this)))
                    (lets ((buff x y (line-up buff)))
                      (values buff
                        (tio (set-cursor x y)))))))
               (else
                 (lets ((buff x y (line-up buff)))
                   (values buff
                     (tio (set-cursor x y)))))))
         ((eq? dir 'down)
            (cond
              ((null? d)
                (values buff null))
              ((eq? y h)
                (lets
                  ((buff tio-scroll (scroll-down buff))
                   (buff tio-move (move-arrow buff dir)))
                  (values buff
                    (append tio-scroll tio-move))))
              ((not (eq? 0 (car off))) ;; there is x-offset
                (let ((next-len (length (car d))))
                  (if (< next-len (car off)) ;; next line start not visible
                    (lets ;; dummy version
                      ((buff tio (move-arrow buff 'left))
                       (buff tio-this (move-arrow buff dir)))
                      (values buff (append tio tio-this)))
                    (lets ((buff x y (line-down buff)))
                      (values buff
                        (tio (set-cursor x y)))))))
              (else
                (lets ((buff x y (line-down buff)))
                  (values buff (tio (set-cursor x y)))))))
         ((eq? dir 'left)
            (cond
               ((null? l)
                  (values buff null))
               ((eq? x 1)
                  (lets
                    ((buff scroll-tio (scroll-left buff))
                     (buff move-tio (move-arrow buff dir)))
                    (values buff (append scroll-tio move-tio))))
               (else
                  (values
                     (buffer u d (cdr l) (cons (car l) r) (- x 1) y w h off meta)
                     (tio
                        (cursor-left 1))))))
         ((eq? dir 'right)
            (cond
               ((null? r)
                  (values buff null))
               ((eq? x w)
                  (lets
                    ((buff scroll-tio (scroll-right buff))
                     (buff move-tio (move-arrow buff dir)))
                    (values buff (append scroll-tio move-tio))))
               (else
                  (values 
                     (buffer u d (cons (car r) l) (cdr r) (+ x 1) y w h off meta)
                     (tio
                        (cursor-right 1))))))
         (else
            (log "odd line move: " dir)
            (values buff null)))))

;;; Undo

(define empty-undo 
   (cons null null))

(define (push-new undo buff)
   (log "pushing new version")
   (lets ((prev new undo))
      ;; no way to return to future after changing the past
      (cons (cons buff prev) null)))


;;; Event dispatcher

(define (led-buffer buff undo mode)
   (log-buff buff)
   (lets ((envelope (wait-mail))
          (from msg envelope))
      (lets ((u d l r x y w h off meta buff))
        (log "cursor " (cons x y) ", offset " off ", event " envelope))
      (if (eq? from 'terminal)
         (if (eq? mode 'insert)
            (tuple-case msg
               ((key x)
                  (lets ((buff out (insert-handle-key buff x)))
                     (mail 'terminal out)
                     (led-buffer buff undo mode)))
               ((enter)
                  (lets 
                     ((u d l r x y w h off meta buff)
                      (u (cons (reverse l) u))
                      (buff (buffer u d null r 1 (+ y 1) w h off meta))
                      (buff reset-tio (reset-left buff)))
                     (mail 'terminal
                        (append reset-tio
                           (tio 
                              (set-cursor 1 (+ y 1)))))
                     (led-buffer buff undo mode)))
               ((backspace)
                  (lets ((buff out (insert-backspace buff)))
                     (mail 'terminal out)
                     (led-buffer buff undo mode)))
               ((arrow dir)
                  (lets ((buff out (move-arrow buff dir)))
                     (mail 'terminal out)
                     (led-buffer buff undo mode)))
               ((end-of-text) 
                  (led-buffer buff (push-new undo buff) 'command))
               ((esc)         
                  (log "switching out of insert mode on esc")
                  (led-buffer buff (push-new undo buff) 'command))
               (else
                  (led-buffer buff undo mode)))
            (tuple-case msg
              ((key k)
                  (cond
                     ((eq? k #\:)
                       (mail 'terminal (tio* (set-cursor 1 (screen-height buff)) (clear-line) (list #\:)))
                       (lets
                          ((ll (interact 'terminal 'get-input))
                           (metadata (buffer-meta buff))
                           (ll res 
                            (readline ll 
                              (get (buffer-meta buff) 'command-history null) 
                              2 (screen-height buff) (screen-width buff))))
                          (log "restoring input stream " ll " to terminal")
                          (mail 'terminal ll) ;; restore input stream
                          (log (str "readline returned '" res "'"))
                          (mail 'terminal 
                           (tio 
                              (set-cursor 1 (screen-height buff)) 
                              (clear-line)
                              (set-cursor (buffer-x buff) (buffer-y buff))
                              ))
                          (if (equal? res "quit")
                            (begin
                              (mail 'terminal
                                (tio
                                  (raw (list #\newline))
                                  (set-cursor 1 (screen-height buff))))
                              (mail 'terminal 'stop)
                              0)
                            (led-buffer 
                              (set-buffer-meta buff
                                (put metadata 'command-history
                                  (cons res (get metadata 'command-history null))))
                              undo 'command))))
                     (else
                        (log "not handling command " msg)
                        (led-buffer buff undo mode))))
              (else
                  (log "not handling command " msg)))))))


;;; Program startup 

(define (splash w h)
    (mail 'terminal
      (tio
        (clear-screen)
        (set-cursor (- (div w 2) (div (string-length version-str) 2)) (div h 2))
        (raw (font-bold (render version-str null)))
        (font-normal)
        (set-cursor 1 1))))

(define (start-led dict args)
  (log "start-led " dict ", " args)
  (lets ((dimensions (interact 'terminal 'get-terminal-size))
         (w h dimensions))
    (log "dimensions " dimensions)
    (lets 
      ((buff 
        (if (= (length args) 1)
          (make-file-state w h (car args) #empty)
          (make-empty-state w h #empty))))
      (if (= (length args) 0)
        (splash w h)
        (mail 'terminal (update-screen buff)))
      (led-buffer buff empty-undo 'insert))))

(define usage-text 
  "Usage: led [flags] [file]")

(define command-line-rules
  (cl-rules
    `((help "-h" "--help" comment "show this thing")
      (version "-V" "--version" comment "show program version"))))

(define (trampoline)
  (let ((env (wait-mail)))
    (log "main: " env)
    (if (and (eq? (ref env 1) 'led) (eq? (ref (ref env 2) 1) 'finished))
      (halt 0)
      (begin
        (print "error: " env)
        (halt 1)))))

(define (start-led-threads dict args)
  (cond
    ((getf dict 'help)
      (print usage-text)
      (print (format-rules command-line-rules))
      0)
    ((getf dict 'version)
      (print version-str)
      0)
    (else
      (log "started " dict ", " args)
      (fork-linked-server 'terminal (λ () (terminal-server stdin 'led)))
      (fork-linked-server 'led (λ () (start-led dict args)))
      (trampoline))))

(define (main args)
  (process-arguments (cdr args) command-line-rules usage-text start-led-threads))

main
