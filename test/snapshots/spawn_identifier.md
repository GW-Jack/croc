# META
~~~ini
description=spawn stays an ordinary identifier where no spawned expression follows it on the same line
type=file:Names.roc
~~~
# SOURCE
~~~roc
Names := [].{
	spawn : U64 -> U64
	spawn = |n| n + 1

	call = spawn(1)

	piped = 3->spawn()

	last = {
		f = spawn
		f(4)
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
LowerIdent,OpColon,UpperIdent,OpArrow,UpperIdent,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,LowerIdent,OpPlus,Int,
LowerIdent,OpAssign,LowerIdent,NoSpaceOpenRound,Int,CloseRound,
LowerIdent,OpAssign,Int,OpArrow,LowerIdent,NoSpaceOpenRound,CloseRound,
LowerIdent,OpAssign,OpenCurly,
LowerIdent,OpAssign,LowerIdent,
LowerIdent,NoSpaceOpenRound,Int,CloseRound,
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
			(header (name "Names")
				(args))
			(ty-tag-union
				(tags))
			(associated
				(s-type-anno (name "spawn")
					(ty-fn
						(ty (name "U64"))
						(ty (name "U64"))))
				(s-decl
					(p-ident (raw "spawn"))
					(e-lambda
						(args
							(p-ident (raw "n")))
						(e-binop (op "+")
							(e-ident (raw "n"))
							(e-int (raw "1")))))
				(s-decl
					(p-ident (raw "call"))
					(e-apply
						(e-ident (raw "spawn"))
						(e-int (raw "1"))))
				(s-decl
					(p-ident (raw "piped"))
					(e-arrow-call
						(e-int (raw "3"))
						(e-apply
							(e-ident (raw "spawn")))))
				(s-decl
					(p-ident (raw "last"))
					(e-block
						(statements
							(s-decl
								(p-ident (raw "f"))
								(e-ident (raw "spawn")))
							(e-apply
								(e-ident (raw "f"))
								(e-int (raw "4"))))))))))
~~~
# FORMATTED
~~~roc
Names := [].{
	spawn : U64 -> U64
	spawn = |n| n + 1

	call = spawn(1)

	piped = 3 |> spawn

	last = {
		f = spawn
		f(4)
	}
}
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "Names.spawn"))
		(e-lambda
			(args
				(p-assign (ident "n")))
			(e-dispatch-call (method "plus") (constraint-fn-var 270)
				(receiver
					(e-lookup-local
						(p-assign (ident "n"))))
				(args
					(e-num (value "1")))))
		(annotation
			(ty-fn (effectful false)
				(ty-lookup (name "U64") (builtin))
				(ty-lookup (name "U64") (builtin)))))
	(d-let
		(p-assign (ident "Names.call"))
		(e-call (constraint-fn-var 274)
			(e-lookup-local
				(p-assign (ident "Names.spawn")))
			(e-num (value "1"))))
	(d-let
		(p-assign (ident "Names.piped"))
		(e-call (constraint-fn-var 277)
			(e-lookup-local
				(p-assign (ident "Names.spawn")))
			(e-num (value "3"))))
	(d-let
		(p-assign (ident "Names.last"))
		(e-block
			(s-let
				(p-assign (ident "f"))
				(e-lookup-local
					(p-assign (ident "Names.spawn"))))
			(e-call (constraint-fn-var 280)
				(e-lookup-local
					(p-assign (ident "f")))
				(e-num (value "4")))))
	(s-nominal-decl
		(ty-header (name "Names"))
		(ty-tag-union)))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "U64 -> U64"))
		(patt (type "U64"))
		(patt (type "U64"))
		(patt (type "U64")))
	(type_decls
		(nominal (type "Names")
			(ty-header (name "Names"))))
	(expressions
		(expr (type "U64 -> U64"))
		(expr (type "U64"))
		(expr (type "U64"))
		(expr (type "U64"))))
~~~
