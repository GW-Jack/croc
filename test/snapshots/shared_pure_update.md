# META
~~~ini
description=A function annotated as pure can't update shared state
type=snippet
~~~
# SOURCE
~~~roc
bump : Shared(U64) -> {}
bump = |counter| counter.modify!(|n| n + 1)
~~~
# EXPECTED
TYPE MISMATCH - shared_pure_update.md:2:8:2:17
# PROBLEMS
~~~clojure
(reports
	(report
		(severity runtime_error)
		(title "Type Mismatch")
		(region (start 2 8) (end 2 17))
		(headline
			(reflow "This expression is used in an unexpected way."))
		(document
			(source-region (file "shared_pure_update.md") (start 2 8) (end 2 17) (annotation error) (line-text "bump = |counter| counter.modify!(|n| n + 1)"))
			(line-break)
			(reflow "It has the type:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "Shared(U64) => {}")
			(annotation-end)
			(line-break)
			(line-break)
			(reflow "But the annotation says it should be:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "Shared(U64) -> {}")
			(annotation-end)
			(line-break)
			(line-break)
			(annotated emphasis "Hint:")
			(reflow " ")
			(reflow "This function is effectful, but a pure function is expected."))))
~~~
# TOKENS
~~~zig
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,UpperIdent,CloseRound,OpArrow,OpenCurly,CloseCurly,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,LowerIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,OpBar,LowerIdent,OpBar,LowerIdent,OpPlus,Int,CloseRound,
EndOfFile,
~~~
# PARSE
~~~clojure
(file
	(type-mod)
	(statements
		(s-type-anno (name "bump")
			(ty-fn
				(ty-apply
					(ty (name "Shared"))
					(ty (name "U64")))
				(ty-record)))
		(s-decl
			(p-ident (raw "bump"))
			(e-lambda
				(args
					(p-ident (raw "counter")))
				(e-method-call (method ".modify!")
					(receiver
						(e-ident (raw "counter")))
					(args
						(e-lambda
							(args
								(p-ident (raw "n")))
							(e-binop (op "+")
								(e-ident (raw "n"))
								(e-int (raw "1"))))))))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "bump"))
		(e-runtime-error (tag "erroneous_value_expr"))
		(annotation
			(ty-fn (effectful false)
				(ty-apply (name "Shared") (builtin)
					(ty-lookup (name "U64") (builtin)))
				(ty-record)))))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "Shared(U64) -> {}")))
	(expressions
		(expr (type "Shared(U64) -> {}"))))
~~~
