# META
~~~ini
description=spawn whose enclosing for! loops in its function run streams, not plans, is a type error
type=file:Loops.roc
~~~
# SOURCE
~~~roc
Loops := [].{
	stream! : Stream(U64), (() => U64) => {}
	stream! = |xs, f| {
		for! _x in xs {
			spawn f
		}
	}

	across_lambda! : List(() => U64), Stream(U64), (() => U64) => {}
	across_lambda! = |fs, xs, f| {
		for! _x in List.concurrently(fs) {
			g! = || {
				for! _y in xs {
					spawn f
				}
			}
			g!()
		}
	}
}
~~~
# EXPECTED
SPAWN OUTSIDE PLAN LOOP - spawn_outside_plan_loop.md:5:4:5:11
SPAWN OUTSIDE PLAN LOOP - spawn_outside_plan_loop.md:14:6:14:13
# PROBLEMS
~~~clojure
(reports
	(report
		(severity runtime_error)
		(title "Spawn Outside Plan Loop")
		(region (start 5 4) (end 5 11))
		(headline
			(reflow "This `spawn` is not inside a `for!` loop over a plan."))
		(document
			(source-region (file "spawn_outside_plan_loop.md") (start 5 4) (end 5 11) (annotation error) (line-text "\t\t\tspawn f"))
			(line-break)
			(line-break)
			(reflow "A `spawn` adds an entry to the innermost `for!` loop around it that runs a plan, a value of type `Concurrently(a)`. The `for!` loops around this one run streams instead, so the `spawn` crashes if it runs.")))
	(report
		(severity runtime_error)
		(title "Spawn Outside Plan Loop")
		(region (start 14 6) (end 14 13))
		(headline
			(reflow "This `spawn` is not inside a `for!` loop over a plan."))
		(document
			(source-region (file "spawn_outside_plan_loop.md") (start 14 6) (end 14 13) (annotation error) (line-text "\t\t\t\t\tspawn f"))
			(line-break)
			(line-break)
			(reflow "A `spawn` adds an entry to the innermost `for!` loop around it that runs a plan, a value of type `Concurrently(a)`. The `for!` loops around this one run streams instead, so the `spawn` crashes if it runs."))))
~~~
# TOKENS
~~~zig
UpperIdent,OpColonEqual,OpenSquare,CloseSquare,Dot,OpenCurly,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,UpperIdent,CloseRound,Comma,OpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,OpenCurly,CloseCurly,
LowerIdent,OpAssign,OpBar,LowerIdent,Comma,LowerIdent,OpBar,OpenCurly,
KwForBang,NamedUnderscore,KwIn,LowerIdent,OpenCurly,
LowerIdent,LowerIdent,
CloseCurly,
CloseCurly,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,Comma,UpperIdent,NoSpaceOpenRound,UpperIdent,CloseRound,Comma,OpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,OpenCurly,CloseCurly,
LowerIdent,OpAssign,OpBar,LowerIdent,Comma,LowerIdent,Comma,LowerIdent,OpBar,OpenCurly,
KwForBang,NamedUnderscore,KwIn,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,OpenCurly,
LowerIdent,OpAssign,OpBar,OpBar,OpenCurly,
KwForBang,NamedUnderscore,KwIn,LowerIdent,OpenCurly,
LowerIdent,LowerIdent,
CloseCurly,
CloseCurly,
LowerIdent,NoSpaceOpenRound,CloseRound,
CloseCurly,
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
				(s-type-anno (name "stream!")
					(ty-fn
						(ty-apply
							(ty (name "Stream"))
							(ty (name "U64")))
						(ty-fn
							(ty (name "U64")))
						(ty-record)))
				(s-decl
					(p-ident (raw "stream!"))
					(e-lambda
						(args
							(p-ident (raw "xs"))
							(p-ident (raw "f")))
						(e-block
							(statements
								(s-for-bang
									(p-ident (raw "_x"))
									(e-ident (raw "xs"))
									(e-block
										(statements
											(e-spawn
												(e-ident (raw "f"))))))))))
				(s-type-anno (name "across_lambda!")
					(ty-fn
						(ty-apply
							(ty (name "List"))
							(ty-fn
								(ty (name "U64"))))
						(ty-apply
							(ty (name "Stream"))
							(ty (name "U64")))
						(ty-fn
							(ty (name "U64")))
						(ty-record)))
				(s-decl
					(p-ident (raw "across_lambda!"))
					(e-lambda
						(args
							(p-ident (raw "fs"))
							(p-ident (raw "xs"))
							(p-ident (raw "f")))
						(e-block
							(statements
								(s-for-bang
									(p-ident (raw "_x"))
									(e-apply
										(e-ident (raw "List.concurrently"))
										(e-ident (raw "fs")))
									(e-block
										(statements
											(s-decl
												(p-ident (raw "g!"))
												(e-lambda
													(args)
													(e-block
														(statements
															(s-for-bang
																(p-ident (raw "_y"))
																(e-ident (raw "xs"))
																(e-block
																	(statements
																		(e-spawn
																			(e-ident (raw "f"))))))))))
											(e-apply
												(e-ident (raw "g!"))))))))))))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "Loops.stream!"))
		(e-lambda
			(args
				(p-assign (ident "xs"))
				(p-assign (ident "f")))
			(e-block
				(s-for-bang
					(p-assign (ident "_x"))
					(e-lookup-local
						(p-assign (ident "xs")))
					(e-block
						(s-expr
							(e-runtime-error (tag "erroneous_value_expr")))
						(e-empty_record)))
				(e-empty_record)))
		(annotation
			(ty-fn (effectful true)
				(ty-apply (name "Stream") (builtin)
					(ty-lookup (name "U64") (builtin)))
				(ty-parens
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-record))))
	(d-let
		(p-assign (ident "Loops.across_lambda!"))
		(e-lambda
			(args
				(p-assign (ident "fs"))
				(p-assign (ident "xs"))
				(p-assign (ident "f")))
			(e-block
				(s-for-bang
					(p-assign (ident "_x"))
					(e-call (constraint-fn-var 449)
						(e-lookup-external
							(builtin))
						(e-lookup-local
							(p-assign (ident "fs"))))
					(e-block
						(s-let
							(p-assign (ident "g!"))
							(e-closure
								(captures
									(capture (ident "xs"))
									(capture (ident "f")))
								(e-lambda
									(args)
									(e-block
										(s-for-bang
											(p-assign (ident "_y"))
											(e-lookup-local
												(p-assign (ident "xs")))
											(e-block
												(s-expr
													(e-runtime-error (tag "erroneous_value_expr")))
												(e-empty_record)))
										(e-empty_record)))))
						(s-expr
							(e-call (constraint-fn-var 559)
								(e-lookup-local
									(p-assign (ident "g!")))))
						(e-empty_record)))
				(e-empty_record)))
		(annotation
			(ty-fn (effectful true)
				(ty-apply (name "List") (builtin)
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-apply (name "Stream") (builtin)
					(ty-lookup (name "U64") (builtin)))
				(ty-parens
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-record))))
	(s-nominal-decl
		(ty-header (name "Loops"))
		(ty-tag-union)))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "Stream(U64), (() => U64) => {}"))
		(patt (type "List(() => U64), Stream(U64), (() => U64) => {}")))
	(type_decls
		(nominal (type "Loops")
			(ty-header (name "Loops"))))
	(expressions
		(expr (type "Stream(U64), (() => U64) => {}"))
		(expr (type "List(() => U64), Stream(U64), (() => U64) => {}"))))
~~~
