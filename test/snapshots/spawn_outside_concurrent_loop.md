# META
~~~ini
description=spawn outside every for! body, or in a closure or expect inside one, is rejected by canonicalization
type=file:Loops.roc
~~~
# SOURCE
~~~roc
Loops := [].{
	outside! : (() => U64) => {}
	outside! = |f| {
		spawn f
	}

	in_for! : List(U64), (() => U64) => {}
	in_for! = |xs, f| {
		for _x in xs {
			spawn f
		}
	}

	in_closure! : List(() => U64), (() => U64) => {}
	in_closure! = |fs, f| {
		for! _x in List.concurrently(fs) {
			g = || spawn f
			g()
		}
	}

	in_expect! : List(() => U64), (() => U64) => {}
	in_expect! = |fs, f| {
		for! _x in List.concurrently(fs) {
			expect {
				spawn f
				Bool.True
			}
		}
	}
}
~~~
# EXPECTED
SPAWN OUTSIDE CONCURRENT LOOP - spawn_outside_concurrent_loop.md:4:3:4:10
SPAWN OUTSIDE CONCURRENT LOOP - spawn_outside_concurrent_loop.md:10:4:10:11
SPAWN OUTSIDE CONCURRENT LOOP - spawn_outside_concurrent_loop.md:17:11:17:18
SPAWN OUTSIDE CONCURRENT LOOP - spawn_outside_concurrent_loop.md:26:5:26:12
# PROBLEMS
~~~clojure
(reports
	(report
		(severity runtime_error)
		(title "Spawn Outside Concurrent Loop")
		(region (start 4 3) (end 4 10))
		(headline
			(reflow "This ")
			(annotated code "spawn")
			(reflow " is not inside a concurrent loop."))
		(document
			(source-region (file "spawn_outside_concurrent_loop.md") (start 4 3) (end 4 10) (annotation error) (line-text "\t\tspawn f"))
			(line-break)
			(reflow "A ")
			(annotated code "spawn")
			(reflow " only works directly inside the body of a ")
			(annotated code "for!")
			(reflow " loop over a plan. It can't be used in a function or closure defined inside the loop, because the loop's running entries can't be captured.")))
	(report
		(severity runtime_error)
		(title "Spawn Outside Concurrent Loop")
		(region (start 10 4) (end 10 11))
		(headline
			(reflow "This ")
			(annotated code "spawn")
			(reflow " is not inside a concurrent loop."))
		(document
			(source-region (file "spawn_outside_concurrent_loop.md") (start 10 4) (end 10 11) (annotation error) (line-text "\t\t\tspawn f"))
			(line-break)
			(reflow "A ")
			(annotated code "spawn")
			(reflow " only works directly inside the body of a ")
			(annotated code "for!")
			(reflow " loop over a plan. It can't be used in a function or closure defined inside the loop, because the loop's running entries can't be captured.")))
	(report
		(severity runtime_error)
		(title "Spawn Outside Concurrent Loop")
		(region (start 17 11) (end 17 18))
		(headline
			(reflow "This ")
			(annotated code "spawn")
			(reflow " is not inside a concurrent loop."))
		(document
			(source-region (file "spawn_outside_concurrent_loop.md") (start 17 11) (end 17 18) (annotation error) (line-text "\t\t\tg = || spawn f"))
			(line-break)
			(reflow "A ")
			(annotated code "spawn")
			(reflow " only works directly inside the body of a ")
			(annotated code "for!")
			(reflow " loop over a plan. It can't be used in a function or closure defined inside the loop, because the loop's running entries can't be captured.")))
	(report
		(severity runtime_error)
		(title "Spawn Outside Concurrent Loop")
		(region (start 26 5) (end 26 12))
		(headline
			(reflow "This ")
			(annotated code "spawn")
			(reflow " is not inside a concurrent loop."))
		(document
			(source-region (file "spawn_outside_concurrent_loop.md") (start 26 5) (end 26 12) (annotation error) (line-text "\t\t\t\tspawn f"))
			(line-break)
			(reflow "A ")
			(annotated code "spawn")
			(reflow " only works directly inside the body of a ")
			(annotated code "for!")
			(reflow " loop over a plan. It can't be used in a function or closure defined inside the loop, because the loop's running entries can't be captured."))))
~~~
# TOKENS
~~~zig
UpperIdent,OpColonEqual,OpenSquare,CloseSquare,Dot,OpenCurly,
LowerIdent,OpColon,OpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,OpenCurly,CloseCurly,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,OpenCurly,
LowerIdent,LowerIdent,
CloseCurly,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,UpperIdent,CloseRound,Comma,OpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,OpenCurly,CloseCurly,
LowerIdent,OpAssign,OpBar,LowerIdent,Comma,LowerIdent,OpBar,OpenCurly,
KwFor,NamedUnderscore,KwIn,LowerIdent,OpenCurly,
LowerIdent,LowerIdent,
CloseCurly,
CloseCurly,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,Comma,OpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,OpenCurly,CloseCurly,
LowerIdent,OpAssign,OpBar,LowerIdent,Comma,LowerIdent,OpBar,OpenCurly,
KwForBang,NamedUnderscore,KwIn,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,OpenCurly,
LowerIdent,OpAssign,OpBar,OpBar,LowerIdent,LowerIdent,
LowerIdent,NoSpaceOpenRound,CloseRound,
CloseCurly,
CloseCurly,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,Comma,OpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,OpenCurly,CloseCurly,
LowerIdent,OpAssign,OpBar,LowerIdent,Comma,LowerIdent,OpBar,OpenCurly,
KwForBang,NamedUnderscore,KwIn,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,OpenCurly,
KwExpect,OpenCurly,
LowerIdent,LowerIdent,
UpperIdent,NoSpaceDotUpperIdent,
CloseCurly,
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
				(s-type-anno (name "outside!")
					(ty-fn
						(ty-fn
							(ty (name "U64")))
						(ty-record)))
				(s-decl
					(p-ident (raw "outside!"))
					(e-lambda
						(args
							(p-ident (raw "f")))
						(e-block
							(statements
								(e-spawn
									(e-ident (raw "f")))))))
				(s-type-anno (name "in_for!")
					(ty-fn
						(ty-apply
							(ty (name "List"))
							(ty (name "U64")))
						(ty-fn
							(ty (name "U64")))
						(ty-record)))
				(s-decl
					(p-ident (raw "in_for!"))
					(e-lambda
						(args
							(p-ident (raw "xs"))
							(p-ident (raw "f")))
						(e-block
							(statements
								(s-for
									(p-ident (raw "_x"))
									(e-ident (raw "xs"))
									(e-block
										(statements
											(e-spawn
												(e-ident (raw "f"))))))))))
				(s-type-anno (name "in_closure!")
					(ty-fn
						(ty-apply
							(ty (name "List"))
							(ty-fn
								(ty (name "U64"))))
						(ty-fn
							(ty (name "U64")))
						(ty-record)))
				(s-decl
					(p-ident (raw "in_closure!"))
					(e-lambda
						(args
							(p-ident (raw "fs"))
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
												(p-ident (raw "g"))
												(e-lambda
													(args)
													(e-spawn
														(e-ident (raw "f")))))
											(e-apply
												(e-ident (raw "g"))))))))))
				(s-type-anno (name "in_expect!")
					(ty-fn
						(ty-apply
							(ty (name "List"))
							(ty-fn
								(ty (name "U64"))))
						(ty-fn
							(ty (name "U64")))
						(ty-record)))
				(s-decl
					(p-ident (raw "in_expect!"))
					(e-lambda
						(args
							(p-ident (raw "fs"))
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
											(s-expect
												(e-block
													(statements
														(e-spawn
															(e-ident (raw "f")))
														(e-tag (raw "Bool.True"))))))))))))))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "Loops.outside!"))
		(e-lambda
			(args
				(p-assign (ident "f")))
			(e-block
				(e-runtime-error (tag "spawn_outside_concurrent_loop"))))
		(annotation
			(ty-fn (effectful true)
				(ty-parens
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-record))))
	(d-let
		(p-assign (ident "Loops.in_for!"))
		(e-lambda
			(args
				(p-assign (ident "xs"))
				(p-assign (ident "f")))
			(e-block
				(s-for
					(p-assign (ident "_x"))
					(e-lookup-local
						(p-assign (ident "xs")))
					(e-block
						(s-runtime-error (tag "spawn_outside_concurrent_loop"))
						(e-empty_record)))
				(e-empty_record)))
		(annotation
			(ty-fn (effectful true)
				(ty-apply (name "List") (builtin)
					(ty-lookup (name "U64") (builtin)))
				(ty-parens
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-record))))
	(d-let
		(p-assign (ident "Loops.in_closure!"))
		(e-lambda
			(args
				(p-assign (ident "fs"))
				(p-assign (ident "f")))
			(e-block
				(s-for-bang
					(p-assign (ident "_x"))
					(e-call (constraint-fn-var 452)
						(e-lookup-external
							(builtin))
						(e-lookup-local
							(p-assign (ident "fs"))))
					(e-block
						(s-let
							(p-assign (ident "g"))
							(e-closure
								(captures
									(capture (ident "f")))
								(e-lambda
									(args)
									(e-runtime-error (tag "spawn_outside_concurrent_loop")))))
						(s-expr
							(e-call (constraint-fn-var 592)
								(e-lookup-local
									(p-assign (ident "g")))))
						(e-empty_record)))
				(e-empty_record)))
		(annotation
			(ty-fn (effectful true)
				(ty-apply (name "List") (builtin)
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-parens
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-record))))
	(d-let
		(p-assign (ident "Loops.in_expect!"))
		(e-lambda
			(args
				(p-assign (ident "fs"))
				(p-assign (ident "f")))
			(e-block
				(s-for-bang
					(p-assign (ident "_x"))
					(e-call (constraint-fn-var 605)
						(e-lookup-external
							(builtin))
						(e-lookup-local
							(p-assign (ident "fs"))))
					(e-block
						(s-expect
							(e-block
								(s-runtime-error (tag "spawn_outside_concurrent_loop"))
								(e-nominal-external
									(builtin)
									(e-tag (name "True")))))
						(e-empty_record)))
				(e-empty_record)))
		(annotation
			(ty-fn (effectful true)
				(ty-apply (name "List") (builtin)
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
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
		(patt (type "(() => U64) => {}"))
		(patt (type "List(U64), (() => U64) => {}"))
		(patt (type "List(() => U64), (() => U64) => {}"))
		(patt (type "List(() => U64), (() => U64) => {}")))
	(type_decls
		(nominal (type "Loops")
			(ty-header (name "Loops"))))
	(expressions
		(expr (type "(() => U64) => {}"))
		(expr (type "List(U64), (() => U64) => {}"))
		(expr (type "List(() => U64), (() => U64) => {}"))
		(expr (type "List(() => U64), (() => U64) => {}"))))
~~~
