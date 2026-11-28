# META
~~~ini
description=spawn inside a for! over a plan, directly and through a nested for, if and match, with each operand form, binds to the plan loop
type=file:Loops.roc
~~~
# SOURCE
~~~roc
Loops := [].{
	direct! : List(() => U64), (() => U64) => U64
	direct! = |fs, f| {
		var $sum = 0
		for! x in List.concurrently(fs) {
			spawn f
			spawn || f()
			spawn (f)
			$sum = $sum + x
		}
		$sum
	}

	nested! : List(() => U64), List(Try(U64, Str)), (U64 -> (() => U64)) => U64
	nested! = |fs, results, make| {
		var $sum = 0
		for! x in List.concurrently(fs) {
			for r in results {
				match r {
					Ok(v) => spawn make(v)
					Err(_) => {}
				}
			}
			if x > 10 {
				spawn make(x)
			}
			$sum = $sum + x
		}
		$sum
	}
}
~~~
# EXPECTED
NIL
# PROBLEMS
NIL
# TOKENS
~~~zig
UpperIdent,OpColonEqual,OpenSquare,CloseSquare,Dot,OpenCurly,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,Comma,OpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,UpperIdent,
LowerIdent,OpAssign,OpBar,LowerIdent,Comma,LowerIdent,OpBar,OpenCurly,
KwVar,LowerIdent,OpAssign,Int,
KwForBang,LowerIdent,KwIn,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,OpenCurly,
LowerIdent,LowerIdent,
LowerIdent,OpBar,OpBar,LowerIdent,NoSpaceOpenRound,CloseRound,
LowerIdent,OpenRound,LowerIdent,CloseRound,
LowerIdent,OpAssign,LowerIdent,OpPlus,LowerIdent,
CloseCurly,
LowerIdent,
CloseCurly,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,Comma,UpperIdent,NoSpaceOpenRound,UpperIdent,NoSpaceOpenRound,UpperIdent,Comma,UpperIdent,CloseRound,CloseRound,Comma,OpenRound,UpperIdent,OpArrow,OpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,CloseRound,OpFatArrow,UpperIdent,
LowerIdent,OpAssign,OpBar,LowerIdent,Comma,LowerIdent,Comma,LowerIdent,OpBar,OpenCurly,
KwVar,LowerIdent,OpAssign,Int,
KwForBang,LowerIdent,KwIn,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,OpenCurly,
KwFor,LowerIdent,KwIn,LowerIdent,OpenCurly,
KwMatch,LowerIdent,OpenCurly,
UpperIdent,NoSpaceOpenRound,LowerIdent,CloseRound,OpFatArrow,LowerIdent,LowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,
UpperIdent,NoSpaceOpenRound,Underscore,CloseRound,OpFatArrow,OpenCurly,CloseCurly,
CloseCurly,
CloseCurly,
KwIf,LowerIdent,OpGreaterThan,Int,OpenCurly,
LowerIdent,LowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,
CloseCurly,
LowerIdent,OpAssign,LowerIdent,OpPlus,LowerIdent,
CloseCurly,
LowerIdent,
CloseCurly,
CloseCurly,
EndOfFile,
~~~
# PARSE
~~~clojure
(file
	(type-mod)
	(statements
		(s-type-decl
			(header (name "Loops")
				(args))
			(ty-tag-union
				(tags))
			(associated
				(s-type-anno (name "direct!")
					(ty-fn
						(ty-apply
							(ty (name "List"))
							(ty-fn
								(ty (name "U64"))))
						(ty-fn
							(ty (name "U64")))
						(ty (name "U64"))))
				(s-decl
					(p-ident (raw "direct!"))
					(e-lambda
						(args
							(p-ident (raw "fs"))
							(p-ident (raw "f")))
						(e-block
							(statements
								(s-var (name "$sum")
									(e-int (raw "0")))
								(s-for-bang
									(p-ident (raw "x"))
									(e-apply
										(e-ident (raw "List.concurrently"))
										(e-ident (raw "fs")))
									(e-block
										(statements
											(e-spawn
												(e-ident (raw "f")))
											(e-spawn
												(e-lambda
													(args)
													(e-apply
														(e-ident (raw "f")))))
											(e-spawn
												(e-tuple
													(e-ident (raw "f"))))
											(s-decl
												(p-ident (raw "$sum"))
												(e-binop (op "+")
													(e-ident (raw "$sum"))
													(e-ident (raw "x")))))))
								(e-ident (raw "$sum"))))))
				(s-type-anno (name "nested!")
					(ty-fn
						(ty-apply
							(ty (name "List"))
							(ty-fn
								(ty (name "U64"))))
						(ty-apply
							(ty (name "List"))
							(ty-apply
								(ty (name "Try"))
								(ty (name "U64"))
								(ty (name "Str"))))
						(ty-fn
							(ty (name "U64"))
							(ty-fn
								(ty (name "U64"))))
						(ty (name "U64"))))
				(s-decl
					(p-ident (raw "nested!"))
					(e-lambda
						(args
							(p-ident (raw "fs"))
							(p-ident (raw "results"))
							(p-ident (raw "make")))
						(e-block
							(statements
								(s-var (name "$sum")
									(e-int (raw "0")))
								(s-for-bang
									(p-ident (raw "x"))
									(e-apply
										(e-ident (raw "List.concurrently"))
										(e-ident (raw "fs")))
									(e-block
										(statements
											(s-for
												(p-ident (raw "r"))
												(e-ident (raw "results"))
												(e-block
													(statements
														(e-match
															(e-ident (raw "r"))
															(branches
																(branch
																	(p-tag (raw "Ok")
																		(p-ident (raw "v")))
																	(e-spawn
																		(e-apply
																			(e-ident (raw "make"))
																			(e-ident (raw "v")))))
																(branch
																	(p-tag (raw "Err")
																		(p-underscore))
																	(e-record)))))))
											(e-if-without-else
												(e-binop (op ">")
													(e-ident (raw "x"))
													(e-int (raw "10")))
												(e-block
													(statements
														(e-spawn
															(e-apply
																(e-ident (raw "make"))
																(e-ident (raw "x")))))))
											(s-decl
												(p-ident (raw "$sum"))
												(e-binop (op "+")
													(e-ident (raw "$sum"))
													(e-ident (raw "x")))))))
								(e-ident (raw "$sum"))))))))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "Loops.direct!"))
		(e-lambda
			(args
				(p-assign (ident "fs"))
				(p-assign (ident "f")))
			(e-block
				(s-var
					(p-var-assign (ident "$sum"))
					(e-num (value "0")))
				(s-for-bang
					(p-assign (ident "x"))
					(e-call (constraint-fn-var 459)
						(e-lookup-external
							(builtin))
						(e-lookup-local
							(p-assign (ident "fs"))))
					(e-block
						(s-expr
							(e-spawn
								(e-lookup-local
									(p-assign (ident "f")))))
						(s-expr
							(e-spawn
								(e-closure
									(captures
										(capture (ident "f")))
									(e-lambda
										(args)
										(e-call (constraint-fn-var 549)
											(e-lookup-local
												(p-assign (ident "f"))))))))
						(s-expr
							(e-spawn
								(e-lookup-local
									(p-assign (ident "f")))))
						(s-reassign
							(p-var-assign (ident "$sum"))
							(e-dispatch-call (method "plus") (constraint-fn-var 550)
								(receiver
									(e-lookup-local
										(p-var-assign (ident "$sum"))))
								(args
									(e-lookup-local
										(p-assign (ident "x"))))))
						(e-empty_record)))
				(e-lookup-local
					(p-var-assign (ident "$sum")))))
		(annotation
			(ty-fn (effectful true)
				(ty-apply (name "List") (builtin)
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-parens
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-lookup (name "U64") (builtin)))))
	(d-let
		(p-assign (ident "Loops.nested!"))
		(e-lambda
			(args
				(p-assign (ident "fs"))
				(p-assign (ident "results"))
				(p-assign (ident "make")))
			(e-block
				(s-var
					(p-var-assign (ident "$sum"))
					(e-num (value "0")))
				(s-for-bang
					(p-assign (ident "x"))
					(e-call (constraint-fn-var 571)
						(e-lookup-external
							(builtin))
						(e-lookup-local
							(p-assign (ident "fs"))))
					(e-block
						(s-for
							(p-assign (ident "r"))
							(e-lookup-local
								(p-assign (ident "results")))
							(e-block
								(s-expr
									(e-match
										(match
											(cond
												(e-lookup-local
													(p-assign (ident "r"))))
											(branches
												(branch
													(patterns
														(pattern (degenerate false)
															(p-applied-tag)))
													(value
														(e-spawn
															(e-call (constraint-fn-var 640)
																(e-lookup-local
																	(p-assign (ident "make")))
																(e-lookup-local
																	(p-assign (ident "v")))))))
												(branch
													(patterns
														(pattern (degenerate false)
															(p-applied-tag)))
													(value
														(e-empty_record)))))))
								(e-empty_record)))
						(s-expr
							(e-if
								(if-branches
									(if-branch
										(e-dispatch-call (method "is_gt") (constraint-fn-var 645)
											(receiver
												(e-lookup-local
													(p-assign (ident "x"))))
											(args
												(e-num (value "10"))))
										(e-block
											(e-spawn
												(e-call (constraint-fn-var 648)
													(e-lookup-local
														(p-assign (ident "make")))
													(e-lookup-local
														(p-assign (ident "x"))))))))
								(if-else
									(e-empty_record))))
						(s-reassign
							(p-var-assign (ident "$sum"))
							(e-dispatch-call (method "plus") (constraint-fn-var 550)
								(receiver
									(e-lookup-local
										(p-var-assign (ident "$sum"))))
								(args
									(e-lookup-local
										(p-assign (ident "x"))))))
						(e-empty_record)))
				(e-lookup-local
					(p-var-assign (ident "$sum")))))
		(annotation
			(ty-fn (effectful true)
				(ty-apply (name "List") (builtin)
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-apply (name "List") (builtin)
					(ty-apply (name "Try") (builtin)
						(ty-lookup (name "U64") (builtin))
						(ty-lookup (name "Str") (builtin))))
				(ty-parens
					(ty-fn (effectful false)
						(ty-lookup (name "U64") (builtin))
						(ty-parens
							(ty-fn (effectful true)
								(ty-lookup (name "U64") (builtin))))))
				(ty-lookup (name "U64") (builtin)))))
	(s-nominal-decl
		(ty-header (name "Loops"))
		(ty-tag-union)))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "List(() => U64), (() => U64) => U64"))
		(patt (type "List(() => U64), List(Try(U64, Str)), (U64 -> (() => U64)) => U64")))
	(type_decls
		(nominal (type "Loops")
			(ty-header (name "Loops"))))
	(expressions
		(expr (type "List(() => U64), (() => U64) => U64"))
		(expr (type "List(() => U64), List(Try(U64, Str)), (U64 -> (() => U64)) => U64"))))
~~~
