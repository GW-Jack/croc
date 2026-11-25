;; A component around the one named $app, which is empty here and which
;; wasmtime.test.mjs replaces with its text. Its `run` calls the inner `run` twice,
;; sees the second call wait for the first, cancels each, and traps unless both
;; report that they were cancelled.
(component
  (import "wasi:clocks/types@0.3.0" (instance $clock-types
    (type $d u64)
    (export "duration" (type (eq $d)))))
  (alias export $clock-types "duration" (type $duration))
  (import "wasi:clocks/monotonic-clock@0.3.0" (instance $clock
    (alias outer 1 $duration (type $d))
    (export "duration" (type $duration' (eq $d)))
    (export "wait-for" (func async (param "how-long" $duration')))))
  (import "wasi:cli/types@0.3.0" (instance $cli-types
    (type $e (enum "io" "illegal-byte-sequence" "pipe"))
    (export "error-code" (type (eq $e)))))
  (alias export $cli-types "error-code" (type $error-code))
  (import "wasi:cli/stdout@0.3.0" (instance $stdout
    (alias outer 1 $error-code (type $e))
    (export "error-code" (type $error-code' (eq $e)))
    (type $bytes (stream u8))
    (type $result (result (error $error-code')))
    (type $done (future $result))
    (export "write-via-stream" (func (param "data" $bytes) (result $done)))))
  (import "wasi:cli/stderr@0.3.0" (instance $stderr
    (alias outer 1 $error-code (type $e))
    (export "error-code" (type $error-code' (eq $e)))
    (type $bytes (stream u8))
    (type $result (result (error $error-code')))
    (type $done (future $result))
    (export "write-via-stream" (func (param "data" $bytes) (result $done)))))

  (component $app)
  (instance $inner (instantiate $app
    (with "wasi:clocks/types@0.3.0" (instance $clock-types))
    (with "wasi:clocks/monotonic-clock@0.3.0" (instance $clock))
    (with "wasi:cli/types@0.3.0" (instance $cli-types))
    (with "wasi:cli/stdout@0.3.0" (instance $stdout))
    (with "wasi:cli/stderr@0.3.0" (instance $stderr))))
  (alias export $inner "wasi:cli/run@0.3.0" (instance $inner-run))
  (alias export $inner-run "run" (func $run))

  (core module $memory (memory (export "memory") 1))
  (core instance $mem (instantiate $memory))
  (alias core export $mem "memory" (core memory $m))
  (core func $run' (canon lower (func $run) async (memory $m)))
  (core func $wait-for (canon lower (func $clock "wait-for") async))
  (core func $set-new (canon waitable-set.new))
  (core func $set-wait (canon waitable-set.wait (memory $m)))
  (core func $join (canon waitable.join))
  (core func $cancel (canon subtask.cancel))
  (core func $drop (canon subtask.drop))

  (core module $main
    (import "" "run" (func $run (param i32) (result i32)))
    (import "" "wait-for" (func $wait-for (param i64) (result i32)))
    (import "" "set-new" (func $set-new (result i32)))
    (import "" "set-wait" (func $set-wait (param i32 i32) (result i32)))
    (import "" "join" (func $join (param i32 i32)))
    (import "" "cancel" (func $cancel (param i32) (result i32)))
    (import "" "drop" (func $drop (param i32)))
    (import "" "memory" (memory 1))

    (func $expect (param $got i32) (param $want i32)
      (if (i32.ne (local.get $got) (local.get $want)) (then unreachable)))

    ;; Let 200 ms pass.
    (func $pause
      (local $set i32) (local $timer i32)
      (local.set $timer (i32.shr_u (call $wait-for (i64.const 200000000)) (i32.const 4)))
      (local.set $set (call $set-new))
      (call $join (local.get $timer) (local.get $set))
      (call $expect (call $set-wait (local.get $set) (i32.const 8)) (i32.const 1))
      (call $expect (i32.load (i32.const 12)) (i32.const 2))
      (call $drop (local.get $timer)))

    (func $cancelled (param $call i32)
      ;; CANCELLED_BEFORE_RETURNED
      (call $expect (call $cancel (i32.shr_u (local.get $call) (i32.const 4))) (i32.const 4))
      (call $drop (i32.shr_u (local.get $call) (i32.const 4))))

    (func (export "run") (result i32)
      (local $first i32) (local $second i32)
      (local.set $first (call $run (i32.const 0)))
      (call $expect (i32.and (local.get $first) (i32.const 15)) (i32.const 1)) ;; STARTED
      (local.set $second (call $run (i32.const 4)))
      (call $expect (i32.and (local.get $second) (i32.const 15)) (i32.const 0)) ;; STARTING
      (call $pause)
      (call $cancelled (local.get $first))
      (call $pause)
      (call $cancelled (local.get $second))
      (i32.const 0)))
  (core instance $main (instantiate $main (with "" (instance
    (export "run" (func $run'))
    (export "wait-for" (func $wait-for))
    (export "set-new" (func $set-new))
    (export "set-wait" (func $set-wait))
    (export "join" (func $join))
    (export "cancel" (func $cancel))
    (export "drop" (func $drop))
    (export "memory" (memory $m))))))

  (func $canceller async (result (result)) (canon lift (core func $main "run")))
  (instance $exported (export "run" (func $canceller)))
  (export "wasi:cli/run@0.3.0" (instance $exported))
)
