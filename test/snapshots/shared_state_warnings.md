# META
~~~ini
description=Warnings about unshared state, lost updates and pauses before cleanups
type=snippet
~~~
# SOURCE
~~~roc
unshared! : () => U64
unshared! = || {
	seen = Shared.new!(0)
	seen.modify!(|n| n + 1)
	seen.get!()
}

lost! : Shared(U64) => {}
lost! = |count| {
	n = count.get!()
	count.modify!(|_| n - 1)
}

pause! : Shared(U64), (() => {}) => {}
pause! = |permits, work!| {
	permits.update!(|n| if n == 0 { Wait } else { Set(n - 1, {}) })
	work!()
	permits.finally!(|n| n + 1, || {})
}
~~~
# EXPECTED
UNSHARED STATE - shared_state_warnings.md:3:2:3:6
LOST UPDATE - shared_state_warnings.md:11:2:11:26
PAUSE BEFORE CLEANUP - shared_state_warnings.md:17:2:17:9
# PROBLEMS
~~~clojure
(reports
	(report
		(severity warning)
		(title "Unshared State")
		(region (start 3 2) (end 3 6))
		(headline
			(reflow "No other task can use the state of")
			(reflow " ")
			(annotated code "seen")
			(reflow "."))
		(document
			(source-region (file "shared_state_warnings.md") (start 3 2) (end 3 6) (annotation warning) (line-text "\tseen = Shared.new!(0)"))
			(line-break)
			(annotated code "seen")
			(reflow " ")
			(reflow "is never captured, passed or stored. State that only one function uses can be a")
			(reflow " ")
			(annotated code "var")
			(reflow " ")
			(reflow "instead.")))
	(report
		(severity warning)
		(title "Lost Update")
		(region (start 11 2) (end 11 26))
		(headline
			(reflow "This replaces the state of")
			(reflow " ")
			(annotated code "count")
			(reflow " ")
			(reflow "with a value computed from an earlier read of it."))
		(document
			(source-region (file "shared_state_warnings.md") (start 11 2) (end 11 26) (annotation warning) (line-text "\tcount.modify!(|_| n - 1)"))
			(line-break)
			(reflow "The earlier read is here:")
			(line-break)
			(source-region (file "shared_state_warnings.md") (start 10 6) (end 10 18) (annotation dim) (line-text "\tn = count.get!()"))
			(line-break)
			(reflow "If another task updates")
			(reflow " ")
			(annotated code "count")
			(reflow " ")
			(reflow "between the two, this overwrites what it stored. Compute the new state from the function's argument, inside one update.")))
	(report
		(severity warning)
		(title "Pause Before Cleanup")
		(region (start 17 2) (end 17 9))
		(headline
			(reflow "This may pause between an update of")
			(reflow " ")
			(annotated code "permits")
			(reflow " ")
			(reflow "and its cleanup."))
		(document
			(source-region (file "shared_state_warnings.md") (start 17 2) (end 17 9) (annotation warning) (line-text "\twork!()"))
			(line-break)
			(reflow "The cleanup is here:")
			(line-break)
			(source-region (file "shared_state_warnings.md") (start 18 2) (end 18 36) (annotation dim) (line-text "\tpermits.finally!(|n| n + 1, || {})"))
			(line-break)
			(reflow "A task that is cancelled where it pauses, or that crashes there, ends without the cleanup, so what the update took is never given back. Move the call before the update or inside the function the cleanup is for."))))
~~~
# TOKENS
~~~zig
LowerIdent,OpColon,OpenRound,CloseRound,OpFatArrow,UpperIdent,
LowerIdent,OpAssign,OpBar,OpBar,OpenCurly,
LowerIdent,OpAssign,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,Int,CloseRound,
LowerIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,OpBar,LowerIdent,OpBar,LowerIdent,OpPlus,Int,CloseRound,
LowerIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,CloseRound,
CloseCurly,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,UpperIdent,CloseRound,OpFatArrow,OpenCurly,CloseCurly,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,OpenCurly,
LowerIdent,OpAssign,LowerIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,CloseRound,
LowerIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,OpBar,Underscore,OpBar,LowerIdent,OpBinaryMinus,Int,CloseRound,
CloseCurly,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,UpperIdent,CloseRound,Comma,OpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,OpenCurly,CloseCurly,CloseRound,OpFatArrow,OpenCurly,CloseCurly,
LowerIdent,OpAssign,OpBar,LowerIdent,Comma,LowerIdent,OpBar,OpenCurly,
LowerIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,OpBar,LowerIdent,OpBar,KwIf,LowerIdent,OpEquals,Int,OpenCurly,UpperIdent,CloseCurly,KwElse,OpenCurly,UpperIdent,NoSpaceOpenRound,LowerIdent,OpBinaryMinus,Int,Comma,OpenCurly,CloseCurly,CloseRound,CloseCurly,CloseRound,
LowerIdent,NoSpaceOpenRound,CloseRound,
LowerIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,OpBar,LowerIdent,OpBar,LowerIdent,OpPlus,Int,Comma,OpBar,OpBar,OpenCurly,CloseCurly,CloseRound,
CloseCurly,
EndOfFile,
~~~
# PARSE
~~~clojure
(file
	(type-mod)
	(statements
		(s-type-anno (name "unshared!")
			(ty-fn
				(ty (name "U64"))))
		(s-decl
			(p-ident (raw "unshared!"))
			(e-lambda
				(args)
				(e-block
					(statements
						(s-decl
							(p-ident (raw "seen"))
							(e-apply
								(e-ident (raw "Shared.new!"))
								(e-int (raw "0"))))
						(e-method-call (method ".modify!")
							(receiver
								(e-ident (raw "seen")))
							(args
								(e-lambda
									(args
										(p-ident (raw "n")))
									(e-binop (op "+")
										(e-ident (raw "n"))
										(e-int (raw "1"))))))
						(e-method-call (method ".get!")
							(receiver
								(e-ident (raw "seen")))
							(args))))))
		(s-type-anno (name "lost!")
			(ty-fn
				(ty-apply
					(ty (name "Shared"))
					(ty (name "U64")))
				(ty-record)))
		(s-decl
			(p-ident (raw "lost!"))
			(e-lambda
				(args
					(p-ident (raw "count")))
				(e-block
					(statements
						(s-decl
							(p-ident (raw "n"))
							(e-method-call (method ".get!")
								(receiver
									(e-ident (raw "count")))
								(args)))
						(e-method-call (method ".modify!")
							(receiver
								(e-ident (raw "count")))
							(args
								(e-lambda
									(args
										(p-underscore))
									(e-binop (op "-")
										(e-ident (raw "n"))
										(e-int (raw "1"))))))))))
		(s-type-anno (name "pause!")
			(ty-fn
				(ty-apply
					(ty (name "Shared"))
					(ty (name "U64")))
				(ty-fn
					(ty-record))
				(ty-record)))
		(s-decl
			(p-ident (raw "pause!"))
			(e-lambda
				(args
					(p-ident (raw "permits"))
					(p-ident (raw "work!")))
				(e-block
					(statements
						(e-method-call (method ".update!")
							(receiver
								(e-ident (raw "permits")))
							(args
								(e-lambda
									(args
										(p-ident (raw "n")))
									(e-if-then-else
										(e-binop (op "==")
											(e-ident (raw "n"))
											(e-int (raw "0")))
										(e-block
											(statements
												(e-tag (raw "Wait"))))
										(e-block
											(statements
												(e-apply
													(e-tag (raw "Set"))
													(e-binop (op "-")
														(e-ident (raw "n"))
														(e-int (raw "1")))
													(e-record))))))))
						(e-apply
							(e-ident (raw "work!")))
						(e-method-call (method ".finally!")
							(receiver
								(e-ident (raw "permits")))
							(args
								(e-lambda
									(args
										(p-ident (raw "n")))
									(e-binop (op "+")
										(e-ident (raw "n"))
										(e-int (raw "1"))))
								(e-lambda
									(args)
									(e-record))))))))))
~~~
# FORMATTED
~~~roc
unshared! : () => U64
unshared! = || {
	seen = Shared.new!(0)
	seen.modify!(|n| n + 1)
	seen.get!()
}

lost! : Shared(U64) => {}
lost! = |count| {
	n = count.get!()
	count.modify!(|_| n - 1)
}

pause! : Shared(U64), (() => {}) => {}
pause! = |permits, work!| {
	permits.update!(
		|n| if n == 0 {
			Wait
		} else {
			Set(n - 1, {})
		},
	)
	work!()
	permits.finally!(|n| n + 1, || {})
}
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "unshared!"))
		(e-lambda
			(args)
			(e-block
				(s-let
					(p-assign (ident "seen"))
					(e-call (constraint-fn-var 352)
						(e-lookup-external
							(builtin))
						(e-num (value "0"))))
				(s-expr
					(e-dispatch-call (method "modify!") (constraint-fn-var 354)
						(receiver
							(e-lookup-local
								(p-assign (ident "seen"))))
						(args
							(e-lambda
								(args
									(p-assign (ident "n")))
								(e-dispatch-call (method "plus") (constraint-fn-var 362)
									(receiver
										(e-lookup-local
											(p-assign (ident "n"))))
									(args
										(e-num (value "1"))))))))
				(e-dispatch-call (method "get!") (constraint-fn-var 365)
					(receiver
						(e-lookup-local
							(p-assign (ident "seen"))))
					(args))))
		(annotation
			(ty-fn (effectful true)
				(ty-lookup (name "U64") (builtin)))))
	(d-let
		(p-assign (ident "lost!"))
		(e-lambda
			(args
				(p-assign (ident "count")))
			(e-block
				(s-let
					(p-assign (ident "n"))
					(e-dispatch-call (method "get!") (constraint-fn-var 378)
						(receiver
							(e-lookup-local
								(p-assign (ident "count"))))
						(args)))
				(e-dispatch-call (method "modify!") (constraint-fn-var 381)
					(receiver
						(e-lookup-local
							(p-assign (ident "count"))))
					(args
						(e-closure
							(captures
								(capture (ident "n")))
							(e-lambda
								(args
									(p-underscore))
								(e-dispatch-call (method "minus") (constraint-fn-var 384)
									(receiver
										(e-lookup-local
											(p-assign (ident "n"))))
									(args
										(e-num (value "1"))))))))))
		(annotation
			(ty-fn (effectful true)
				(ty-apply (name "Shared") (builtin)
					(ty-lookup (name "U64") (builtin)))
				(ty-record))))
	(d-let
		(p-assign (ident "pause!"))
		(e-lambda
			(args
				(p-assign (ident "permits"))
				(p-assign (ident "work!")))
			(e-block
				(s-expr
					(e-dispatch-call (method "update!") (constraint-fn-var 395)
						(receiver
							(e-lookup-local
								(p-assign (ident "permits"))))
						(args
							(e-lambda
								(args
									(p-assign (ident "n")))
								(e-if
									(if-branches
										(if-branch
											(e-method-eq (negated "false")
												(lhs
													(e-lookup-local
														(p-assign (ident "n"))))
												(rhs
													(e-num (value "0"))))
											(e-block
												(e-tag (name "Wait")))))
									(if-else
										(e-block
											(e-tag (name "Set")
												(args
													(e-dispatch-call (method "minus") (constraint-fn-var 384)
														(receiver
															(e-lookup-local
																(p-assign (ident "n"))))
														(args
															(e-num (value "1"))))
													(e-empty_record))))))))))
				(s-expr
					(e-call (constraint-fn-var 413)
						(e-lookup-local
							(p-assign (ident "work!")))))
				(e-dispatch-call (method "finally!") (constraint-fn-var 415)
					(receiver
						(e-lookup-local
							(p-assign (ident "permits"))))
					(args
						(e-lambda
							(args
								(p-assign (ident "n")))
							(e-dispatch-call (method "plus") (constraint-fn-var 370)
								(receiver
									(e-lookup-local
										(p-assign (ident "n"))))
								(args
									(e-num (value "1")))))
						(e-lambda
							(args)
							(e-empty_record))))))
		(annotation
			(ty-fn (effectful true)
				(ty-apply (name "Shared") (builtin)
					(ty-lookup (name "U64") (builtin)))
				(ty-parens
					(ty-fn (effectful true)
						(ty-record)))
				(ty-record)))))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "() => U64"))
		(patt (type "Shared(U64) => {}"))
		(patt (type "Shared(U64), (() => {}) => {}")))
	(expressions
		(expr (type "() => U64"))
		(expr (type "Shared(U64) => {}"))
		(expr (type "Shared(U64), (() => {}) => {}"))))
~~~
