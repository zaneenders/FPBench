#lang racket

(require "../tools/common.rkt" "../tools/core2c.rkt" "../tools/fpcore.rkt")

(define tests-to-run (make-parameter 10))
(define test-file (make-parameter "/tmp/test.c"))
(define fuel (make-parameter 1000))

(define ((eval-fuel evaltor fuel [default #f]) expr ctx)
  (let/ec k
    (let eval ([expr expr] [ctx ctx] [fuel fuel])
      (if (<= fuel 0)
          (k default)
          ((eval-expr* evaltor (λ (expr ctx) (eval expr ctx (- fuel 1)))) expr ctx)))))

(define (random-exp k)
  "Like (random (expt 2 k)), but k is allowed to be arbitrarily large"
  (if (< k 31) ; Racket generates random numbers in the range [0, 2^32-2]; I think it's a bug
      (random (expt 2 k))
      (let ([head (* (expt 2 31) (random-exp (- k 31)))])
        (+ head (random (expt 2 31))))))

(define (sample-double)
  (floating-point-bytes->real (integer->integer-bytes (random-exp 64) 8 #f)))

(define (sample-single)
  (real->single-flonum (floating-point-bytes->real (integer->integer-bytes (random-exp 32) 4 #f))))

(define (compile->c prog test-file #:type [type 'binary64])
  (call-with-output-file test-file #:exists 'replace
    (λ (p)
      (define N (length (second prog)))
      (fprintf p "#include <stdlib.h>\n#include <stdio.h>\n#include <math.h>\n\n~a\n\n" (compile-program prog #:name "f"))
      (fprintf p "int main(int argc, char **argv) { ")
      (define strtox (match type ['binary64 "strtod"] ['binary32 "strtof"]))
      (fprintf p "printf(\"%.20g\", f(~a)); return 0; }\n"
               (string-join (map (curry format "~a(argv[~a], NULL)" strtox) (map add1 (range N))) ", "))))
  (define c-file (string-replace test-file ".c" ".bin"))
  (system (format "cc ~a -lm -o ~a" test-file c-file))
  c-file)

(define (run<-c exec-name ctx #:type [type 'binary64])
  (define out
    (with-output-to-string
     (λ ()
       (system (string-join (cons exec-name (map (compose ~a real->double-flonum) (dict-values ctx))) " ")))))
  (define out*
    (match out
      ["nan" "+nan.0"]
      ["-nan" "+nan.0"]
      ["inf" "+inf.0"]
      ["-inf" "-inf.0"]
      [x x]))
  ((match type
     ['binary64 real->double-flonum]
     ['binary32 real->single-flonum])
   (string->number out*)))

(define (=* a b)
  (or (equal? a b) (= a b) (and (nan? a) (nan? b))))

(module+ main
  (command-line
   #:program "test/compiler.rkt"
   #:once-each
   ["--fuel" fuel_ "Number of computation steps to allow"
    (fuel (string->number fuel_))]
   ["--repeat" repeat_ "Number of times to test each program"
    (tests-to-run (string->number repeat_))]
   ["-o" name_ "Name for generated C file"
    (test-file name_)]
   #:args files
   (for ([file files])
     (call-with-input-file file
       (λ (p)
         (define error 0)
         (for ([prog (in-port read p)])
           (match-define (list 'FPCore (list vars ...) props* ... body) prog)
           (define-values (_ props) (parse-properties props*))
           (define type (dict-ref props ':type 'binary64))
           (define exec-file (compile->c prog (test-file) #:type type))
           (define timeout 0)
           (define results
             (for/list ([i (in-range (tests-to-run))])
               (define ctx (for/list ([var vars])
                             (cons var (match type
                                         ['binary64 (sample-double)]
                                         ['binary32 (sample-single)]))))
               (define evaltor (match type ['binary64 racket-double-evaluator] ['binary32 racket-single-evaluator]))
               (define out
                 (match ((eval-fuel evaltor (fuel) 'timeout) body ctx)
                   [(? real? result)
                    ((match type
                      ['binary64 real->double-flonum] ['binary32 real->single-flonum])
                     result)]
                   [(? complex? result)
                    (match type
                      ['binary64 +nan.0] ['binary32 +nan.f])]
                   ['timeout 'timeout]
                   [(? boolean? result) result]))
               (when (equal? out 'timeout)
                 (set! timeout (+ timeout 1)))
               (define out* (if (equal? out 'timeout) 'timeout (run<-c exec-file ctx #:type type)))
               (list ctx out out*)))
           (unless (null? results)
             (printf "~a/~a: ~a~a\n" (count (λ (x) (=* (second x) (third x))) results) (length results)
                     (dict-ref props ':name body) (match timeout
                                                    [0 ""]
                                                    [1 " (1 timeout)"]
                                                    [_ (format " (~a timeouts)" timeout)]))
             (set! error (+ error (count (λ (x) (not (=* (second x) (third x)))) results)))
             (for ([x (in-list results)] #:unless (=* (second x) (third x)))
               (printf "\t~a ≠ ~a @ ~a\n" (second x) (third x)
                       (string-join (map (λ (x) (format "~a = ~a" (car x) (cdr x))) (first x)) ", ")))))
         (exit error))))))