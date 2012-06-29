;;; Guix --- Nix package management from Guile.         -*- coding: utf-8 -*-
;;; Copyright (C) 2012 Ludovic Courtès <ludo@gnu.org>
;;;
;;; This file is part of Guix.
;;;
;;; Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (guix utils)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-39)
  #:use-module (srfi srfi-60)
  #:use-module (rnrs bytevectors)
  #:use-module ((rnrs io ports) #:select (put-bytevector))
  #:use-module (ice-9 vlist)
  #:use-module (ice-9 format)
  #:autoload   (ice-9 popen)  (open-pipe*)
  #:autoload   (ice-9 rdelim) (read-line)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 match)
  #:autoload   (system foreign) (pointer->procedure)
  #:export (bytevector-quintet-length
            bytevector->base32-string
            bytevector->nix-base32-string
            bytevector->base16-string
            base32-string->bytevector
            nix-base32-string->bytevector
            base16-string->bytevector
            sha256

            %nixpkgs-directory
            nixpkgs-derivation

            define-record-type*
            compile-time-value
            memoize
            gnu-triplet->nix-system
            %current-system))


;;;
;;; Compile-time computations.
;;;

(define-syntax compile-time-value
  (syntax-rules ()
    "Evaluate the given expression at compile time.  The expression must
evaluate to a simple datum."
    ((_ exp)
     (let-syntax ((v (lambda (s)
                       (let ((val exp))
                         (syntax-case s ()
                           (_ #`'#,(datum->syntax s val)))))))
       v))))


;;;
;;; Base 32.
;;;

(define bytevector-quintet-ref
  (let* ((ref  bytevector-u8-ref)
         (ref+ (lambda (bv offset)
                 (let ((o (+ 1 offset)))
                   (if (>= o (bytevector-length bv))
                       0
                       (bytevector-u8-ref bv o)))))
         (ref0 (lambda (bv offset)
                 (bit-field (ref bv offset) 3 8)))
         (ref1 (lambda (bv offset)
                 (logior (ash (bit-field (ref bv offset) 0 3) 2)
                         (bit-field (ref+ bv offset) 6 8))))
         (ref2 (lambda (bv offset)
                 (bit-field (ref bv offset) 1 6)))
         (ref3 (lambda (bv offset)
                 (logior (ash (bit-field (ref bv offset) 0 1) 4)
                         (bit-field (ref+ bv offset) 4 8))))
         (ref4 (lambda (bv offset)
                 (logior (ash (bit-field (ref bv offset) 0 4) 1)
                         (bit-field (ref+ bv offset) 7 8))))
         (ref5 (lambda (bv offset)
                 (bit-field (ref bv offset) 2 7)))
         (ref6 (lambda (bv offset)
                 (logior (ash (bit-field (ref bv offset) 0 2) 3)
                         (bit-field (ref+ bv offset) 5 8))))
         (ref7 (lambda (bv offset)
                 (bit-field (ref bv offset) 0 5)))
         (refs (vector ref0 ref1 ref2 ref3 ref4 ref5 ref6 ref7)))
    (lambda (bv index)
      "Return the INDEXth quintet of BV."
      (let ((p (vector-ref refs (modulo index 8))))
        (p bv (quotient (* index 5) 8))))))

(define bytevector-quintet-ref-right
  (let* ((ref  bytevector-u8-ref)
         (ref+ (lambda (bv offset)
                 (let ((o (+ 1 offset)))
                   (if (>= o (bytevector-length bv))
                       0
                       (bytevector-u8-ref bv o)))))
         (ref0 (lambda (bv offset)
                 (bit-field (ref bv offset) 0 5)))
         (ref1 (lambda (bv offset)
                 (logior (bit-field (ref bv offset) 5 8)
                         (ash (bit-field (ref+ bv offset) 0 2) 3))))
         (ref2 (lambda (bv offset)
                 (bit-field (ref bv offset) 2 7)))
         (ref3 (lambda (bv offset)
                 (logior (bit-field (ref bv offset) 7 8)
                         (ash (bit-field (ref+ bv offset) 0 4) 1))))
         (ref4 (lambda (bv offset)
                 (logior (bit-field (ref bv offset) 4 8)
                         (ash (bit-field (ref+ bv offset) 0 1) 4))))
         (ref5 (lambda (bv offset)
                 (bit-field (ref bv offset) 1 6)))
         (ref6 (lambda (bv offset)
                 (logior (bit-field (ref bv offset) 6 8)
                         (ash (bit-field (ref+ bv offset) 0 3) 2))))
         (ref7 (lambda (bv offset)
                 (bit-field (ref bv offset) 3 8)))
         (refs (vector ref0 ref1 ref2 ref3 ref4 ref5 ref6 ref7)))
    (lambda (bv index)
      "Return the INDEXth quintet of BV, assuming quintets start from the
least-significant bits, contrary to what RFC 4648 describes."
      (let ((p (vector-ref refs (modulo index 8))))
        (p bv (quotient (* index 5) 8))))))

(define (bytevector-quintet-length bv)
  "Return the number of quintets (including truncated ones) available in BV."
  (ceiling (/ (* (bytevector-length bv) 8) 5)))

(define (bytevector-quintet-fold proc init bv)
  "Return the result of applying PROC to each quintet of BV and the result of
the previous application or INIT."
  (define len
    (bytevector-quintet-length bv))

  (let loop ((i 0)
             (r init))
    (if (= i len)
        r
        (loop (1+ i) (proc (bytevector-quintet-ref bv i) r)))))

(define (bytevector-quintet-fold-right proc init bv)
  "Return the result of applying PROC to each quintet of BV and the result of
the previous application or INIT."
  (define len
    (bytevector-quintet-length bv))

  (let loop ((i len)
             (r init))
    (if (zero? i)
        r
        (let ((j (- i 1)))
          (loop j (proc (bytevector-quintet-ref-right bv j) r))))))

(define (make-bytevector->base32-string quintet-fold base32-chars)
  (lambda (bv)
    "Return a base32 encoding of BV using BASE32-CHARS as the alphabet."
    (let ((chars (quintet-fold (lambda (q r)
                                 (cons (vector-ref base32-chars q)
                                       r))
                               '()
                               bv)))
      (list->string (reverse chars)))))

(define %nix-base32-chars
  ;; See `libutil/hash.cc'.
  #(#\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9
    #\a #\b #\c #\d #\f #\g #\h #\i #\j #\k #\l #\m #\n
    #\p #\q #\r #\s #\v #\w #\x #\y #\z))

(define %rfc4648-base32-chars
  #(#\a #\b #\c #\d #\e #\f #\g #\h #\i #\j #\k #\l #\m
    #\n #\o #\p #\q #\r #\s #\t #\u #\v #\w #\x #\y #\z
    #\2 #\3 #\4 #\5 #\6 #\7))

(define bytevector->base32-string
  (make-bytevector->base32-string bytevector-quintet-fold
                                  %rfc4648-base32-chars))

(define bytevector->nix-base32-string
  (make-bytevector->base32-string bytevector-quintet-fold-right
                                  %nix-base32-chars))


(define bytevector-quintet-set!
  (let* ((setq! (lambda (bv offset start stop value)
                  (let ((v (bytevector-u8-ref bv offset))
                        (w (arithmetic-shift value start))
                        (m (bitwise-xor (1- (expt 2 stop))
                                        (1- (expt 2 start)))))
                    (bytevector-u8-set! bv offset
                                        (bitwise-merge m w v)))))
         (set0! (lambda (bv offset value)
                  (setq! bv offset 3 8 value)))
         (set1! (lambda (bv offset value)
                  (setq! bv offset 0 3 (bit-field value 2 5))
                  (or (= (+ 1 offset) (bytevector-length bv))
                      (setq! bv (+ 1 offset) 6 8 (bit-field value 0 2)))))
         (set2! (lambda (bv offset value)
                  (setq! bv offset 1 6 value)))
         (set3! (lambda (bv offset value)
                  (setq! bv offset 0 1 (bit-field value 4 5))
                  (or (= (+ 1 offset) (bytevector-length bv))
                      (setq! bv (+ 1 offset) 4 8 (bit-field value 0 4)))))
         (set4! (lambda (bv offset value)
                  (setq! bv offset 0 4 (bit-field value 1 5))
                  (or (= (+ 1 offset) (bytevector-length bv))
                      (setq! bv (+ 1 offset) 7 8  (bit-field value 0 1)))))
         (set5! (lambda (bv offset value)
                  (setq! bv offset 2 7 value)))
         (set6! (lambda (bv offset value)
                  (setq! bv offset 0 2 (bit-field value 3 5))
                  (or (= (+ 1 offset) (bytevector-length bv))
                      (setq! bv (+ 1 offset) 5 8 (bit-field value 0 3)))))
         (set7! (lambda (bv offset value)
                  (setq! bv offset 0 5 value)))
         (sets  (vector set0! set1! set2! set3! set4! set5! set6! set7!)))
    (lambda (bv index value)
      "Set the INDEXth quintet of BV to VALUE."
      (let ((p (vector-ref sets (modulo index 8))))
        (p bv (quotient (* index 5) 8) (logand value #x1f))))))

(define bytevector-quintet-set-right!
  (let* ((setq! (lambda (bv offset start stop value)
                  (let ((v (bytevector-u8-ref bv offset))
                        (w (arithmetic-shift value start))
                        (m (bitwise-xor (1- (expt 2 stop))
                                        (1- (expt 2 start)))))
                    (bytevector-u8-set! bv offset
                                        (bitwise-merge m w v)))))
         (set0! (lambda (bv offset value)
                  (setq! bv offset 0 5 value)))
         (set1! (lambda (bv offset value)
                  (setq! bv offset 5 8 (bit-field value 0 3))
                  (or (= (+ 1 offset) (bytevector-length bv))
                      (setq! bv (+ 1 offset) 0 2 (bit-field value 3 5)))))
         (set2! (lambda (bv offset value)
                  (setq! bv offset 2 7 value)))
         (set3! (lambda (bv offset value)
                  (setq! bv offset 7 8 (bit-field value 0 1))
                  (or (= (+ 1 offset) (bytevector-length bv))
                      (setq! bv (+ 1 offset) 0 4 (bit-field value 1 5)))))
         (set4! (lambda (bv offset value)
                  (setq! bv offset 4 8 (bit-field value 0 4))
                  (or (= (+ 1 offset) (bytevector-length bv))
                      (setq! bv (+ 1 offset) 0 1 (bit-field value 4 5)))))
         (set5! (lambda (bv offset value)
                  (setq! bv offset 1 6 value)))
         (set6! (lambda (bv offset value)
                  (setq! bv offset 6 8 (bit-field value 0 2))
                  (or (= (+ 1 offset) (bytevector-length bv))
                      (setq! bv (+ 1 offset) 0 3 (bit-field value 2 5)))))
         (set7! (lambda (bv offset value)
                  (setq! bv offset 3 8 value)))
         (sets  (vector set0! set1! set2! set3! set4! set5! set6! set7!)))
    (lambda (bv index value)
      "Set the INDEXth quintet of BV to VALUE, assuming quintets start from
the least-significant bits."
      (let ((p (vector-ref sets (modulo index 8))))
        (p bv (quotient (* index 5) 8) (logand value #x1f))))))

(define (base32-string-unfold f s)
  "Given procedure F which, when applied to a character, returns the
corresponding quintet, return the bytevector corresponding to string S."
  (define len (string-length s))

  (let ((bv (make-bytevector (quotient (* len 5) 8))))
    (string-fold (lambda (chr index)
                   (bytevector-quintet-set! bv index (f chr))
                   (+ 1 index))
                 0
                 s)
    bv))

(define (base32-string-unfold-right f s)
  "Given procedure F which, when applied to a character, returns the
corresponding quintet, return the bytevector corresponding to string S,
starting from the right of S."
  (define len (string-length s))

  (let ((bv (make-bytevector (quotient (* len 5) 8))))
    (string-fold-right (lambda (chr index)
                         (bytevector-quintet-set-right! bv index (f chr))
                         (+ 1 index))
                       0
                       s)
    bv))

(define (make-base32-string->bytevector base32-string-unfold base32-chars)
  (let ((char->value (let loop ((i 0)
                                (v vlist-null))
                       (if (= i (vector-length base32-chars))
                           v
                           (loop (+ 1 i)
                                 (vhash-consv (vector-ref base32-chars i)
                                              i v))))))
    (lambda (s)
      "Return the binary representation of base32 string S as a bytevector."
      (base32-string-unfold (lambda (chr)
                              (or (and=> (vhash-assv chr char->value) cdr)
                                  (error "invalid base32 character" chr)))
                            s))))

(define base32-string->bytevector
  (make-base32-string->bytevector base32-string-unfold %rfc4648-base32-chars))

(define nix-base32-string->bytevector
  (make-base32-string->bytevector base32-string-unfold-right %nix-base32-chars))



;;;
;;; Base 16.
;;;

(define (bytevector->base16-string bv)
  "Return the hexadecimal representation of BV's contents."
  (define len
    (bytevector-length bv))

  (let-syntax ((base16-chars (lambda (s)
                               (syntax-case s ()
                                 (_
                                  (let ((v (list->vector
                                            (unfold (cut > <> 255)
                                                    (lambda (n)
                                                      (format #f "~2,'0x" n))
                                                    1+
                                                    0))))
                                    v))))))
    (define chars base16-chars)
    (let loop ((i 0)
               (r '()))
      (if (= i len)
          (string-concatenate-reverse r)
          (loop (+ 1 i)
                (cons (vector-ref chars (bytevector-u8-ref bv i)) r))))))

(define base16-string->bytevector
  (let ((chars->value (fold (lambda (i r)
                              (vhash-consv (string-ref (number->string i 16)
                                                       0)
                                           i r))
                            vlist-null
                            (iota 16))))
    (lambda (s)
      "Return the bytevector whose hexadecimal representation is string S."
      (define bv
        (make-bytevector (quotient (string-length s) 2) 0))

      (string-fold (lambda (chr i)
                     (let ((j (quotient i 2))
                           (v (and=> (vhash-assv chr chars->value) cdr)))
                       (if v
                           (if (zero? (logand i 1))
                               (bytevector-u8-set! bv j
                                                   (arithmetic-shift v 4))
                               (let ((w (bytevector-u8-ref bv j)))
                                 (bytevector-u8-set! bv j (logior v w))))
                           (error "invalid hexadecimal character" chr)))
                     (+ i 1))
                   0
                   s)
      bv)))


;;;
;;; Hash.
;;;

(define sha256
  (cond
   ((compile-time-value
     (false-if-exception (dynamic-link "libgcrypt")))
    ;; Using libgcrypt.
    (let ((hash   (pointer->procedure void
                                      (dynamic-func "gcry_md_hash_buffer"
                                                    (dynamic-link "libgcrypt"))
                                      `(,int * * ,size_t)))
          (sha256 8))                           ; GCRY_MD_SHA256, as of 1.5.0
      (lambda (bv)
        "Return the SHA256 of BV as a bytevector."
        (let ((digest (make-bytevector (/ 256 8))))
          (hash sha256 (bytevector->pointer digest)
                (bytevector->pointer bv) (bytevector-length bv))
          digest))))

   ((compile-time-value
     (false-if-exception (resolve-interface '(chop hash))))
    ;; Using libchop.
    (let ((bytevector-hash    (@ (chop hash) bytevector-hash))
          (hash-method/sha256 (@ (chop hash) hash-method/sha256)))
      (lambda (bv)
        "Return the SHA256 of BV as a bytevector."
        (bytevector-hash hash-method/sha256 bv))))

   (else
    ;; Slow, poor programmer's implementation that uses Coreutils.
    (lambda (bv)
      "Return the SHA256 of BV as a bytevector."
      (let ((in  (pipe))
            (out (pipe))
            (pid (primitive-fork)))
        (if (= 0 pid)
            (begin                                 ; child
              (close (cdr in))
              (close (car out))
              (close 0)
              (close 1)
              (dup2 (fileno (car in)) 0)
              (dup2 (fileno (cdr out)) 1)
              (execlp "sha256sum" "sha256sum"))
            (begin                                 ; parent
              (close (car in))
              (close (cdr out))
              (put-bytevector (cdr in) bv)
              (close (cdr in))                     ; EOF
              (let ((line (car (string-tokenize (read-line (car out))))))
                (close (car out))
                (and (and=> (status:exit-val (cdr (waitpid pid)))
                            zero?)
                     (base16-string->bytevector line))))))))))



;;;
;;; Nixpkgs.
;;;

(define %nixpkgs-directory
  (make-parameter
   ;; Capture the build-time value of $NIXPKGS.
   (compile-time-value (getenv "NIXPKGS"))))

(define (nixpkgs-derivation attribute)
  "Return the derivation path of ATTRIBUTE in Nixpkgs."
  (let* ((p (open-pipe* OPEN_READ "nix-instantiate" "-A"
                        attribute (%nixpkgs-directory)))
         (l (read-line p))
         (s (close-pipe p)))
    (and (zero? (status:exit-val s))
         (not (eof-object? l))
         l)))


;;;
;;; Miscellaneous.
;;;

(define-syntax define-record-type*
  (lambda (s)
    "Define the given record type such that an additional \"syntactic
constructor\" is defined, which allows instances to be constructed with named
field initializers, à la SRFI-35, as well as default values."
    (define (make-syntactic-constructor name ctor fields defaults)
      "Make the syntactic constructor NAME that calls CTOR, and expects all
of FIELDS to be initialized.  DEFAULTS is the list of FIELD/DEFAULT-VALUE
tuples."
      (with-syntax ((name     name)
                    (ctor     ctor)
                    (expected fields)
                    (defaults defaults))
        #'(define-syntax name
            (lambda (s)
              (syntax-case s expected
                ((_ (field value) (... ...))
                 (let ((fields   (map syntax->datum #'(field (... ...))))
                       (inits    (map (match-lambda
                                       ((f v)
                                        (list (syntax->datum f) v)))
                                      #'((field value) (... ...))))
                       (dflt      (map (match-lambda
                                        ((f v)
                                         (list (syntax->datum f) v)))
                                       #'defaults)))

                   (define (field-value f)
                     (match (assoc f inits)
                       ((_ v) v)
                       (#f (car (assoc-ref dflt f)))))

                   (if (lset= eq? (append fields (map car dflt))
                              'expected)
                       #`(ctor #,@(map field-value 'expected))
                       (error "missing or extraneous field initializers"
                              (lset-difference eq? fields 'expected))))))))))

    (define (field-default-value s)
      (syntax-case s (default)
        ((field (default val) _ ...)
         (list #'field #'val))
        ((field _ options ...)
         (field-default-value #'(field options ...)))
        (_ #f)))

    (syntax-case s ()
      ((_ type syntactic-ctor ctor pred
          (field get options ...) ...)
       #`(begin
           (define-record-type type
             (ctor field ...)
             pred
             (field get) ...)
           #,(make-syntactic-constructor #'syntactic-ctor #'ctor
                                         #'(field ...)
                                         (filter-map field-default-value
                                                     #'((field options ...)
                                                        ...))))))))

(define (memoize proc)
  "Return a memoizing version of PROC."
  (let ((cache (make-hash-table)))
    (lambda args
      (let ((results (hash-ref cache args)))
        (if results
            (apply values results)
            (let ((results (call-with-values (lambda ()
                                               (apply proc args))
                             list)))
              (hash-set! cache args results)
              (apply values results)))))))

(define (gnu-triplet->nix-system triplet)
  "Return the Nix system type corresponding to TRIPLET, a GNU triplet as
returned by `config.guess'."
  (let ((triplet (cond ((string-match "^i[345]86-(.*)$" triplet)
                        =>
                        (lambda (m)
                          (string-append "i686-" (match:substring m 1))))
                       (else triplet))))
    (cond ((string-match "^([^-]+)-([^-]+-)?linux-gnu.*" triplet)
           =>
           (lambda (m)
             ;; Nix omits `-gnu' for GNU/Linux.
             (string-append (match:substring m 1) "-linux")))
          ((string-match "^([^-]+)-([^-]+-)?([[:alpha:]]+)([0-9]+\\.?)*$" triplet)
           =>
           (lambda (m)
             ;; Nix strip the version number from names such as `gnu0.3',
             ;; `darwin10.2.0', etc., and always strips the vendor part.
             (string-append (match:substring m 1) "-"
                            (match:substring m 3))))
          (else triplet))))

(define %current-system
  ;; System type as expected by Nix, usually ARCHITECTURE-KERNEL.
  (make-parameter (gnu-triplet->nix-system %host-type)))
