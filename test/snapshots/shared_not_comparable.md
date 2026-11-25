# META
~~~ini
description=Handles to shared state can't be compared, since == would read state
type=snippet
~~~
# SOURCE
~~~roc
same! : Shared(U64), Shared(U64) => Bool
same! = |a, b| a == b
~~~
# EXPECTED
MISSING METHOD - shared_not_comparable.md:2:16:2:22
# PROBLEMS
~~~clojure
(reports
	(report
		(severity runtime_error)
		(title "Missing Method")
		(region (start 2 16) (end 2 22))
		(headline
			(reflow "The value before this")
			(reflow " ")
			(annotated operator "==")
			(reflow " ")
			(reflow "operator has a type that doesn't have a")
			(reflow " ")
			(annotated code "is_eq")
			(reflow " ")
			(reflow "method."))
		(document
			(source-region (file "shared_not_comparable.md") (start 2 16) (end 2 22) (annotation error) (line-text "same! = |a, b| a == b"))
			(line-break)
			(reflow "The value's type, which does not have a method named ")
			(annotated code "is_eq")
			(reflow ",")
			(reflow " ")
			(reflow "is:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "Shared(U64)")
			(annotation-end)
			(line-break)
			(line-break)
			(annotated emphasis "Hint:")
			(reflow " ")
			(reflow "The")
			(reflow " ")
			(annotated operator "==")
			(reflow " ")
			(reflow "operator calls a method named")
			(reflow " ")
			(annotated code "is_eq")
			(reflow " ")
			(reflow "on the value preceding it, passing the value after the operator as the one argument."))))
~~~
# TOKENS
~~~zig
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,UpperIdent,CloseRound,Comma,UpperIdent,NoSpaceOpenRound,UpperIdent,CloseRound,OpFatArrow,UpperIdent,
LowerIdent,OpAssign,OpBar,LowerIdent,Comma,LowerIdent,OpBar,LowerIdent,OpEquals,LowerIdent,
EndOfFile,
~~~
# PARSE
~~~clojure
(file
	(type-mod)
	(statements
		(s-type-anno (name "same!")
			(ty-fn
				(ty-apply
					(ty (name "Shared"))
					(ty (name "U64")))
				(ty-apply
					(ty (name "Shared"))
					(ty (name "U64")))
				(ty (name "Bool"))))
		(s-decl
			(p-ident (raw "same!"))
			(e-lambda
				(args
					(p-ident (raw "a"))
					(p-ident (raw "b")))
				(e-binop (op "==")
					(e-ident (raw "a"))
					(e-ident (raw "b")))))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "same!"))
		(e-lambda
			(args
				(p-assign (ident "a"))
				(p-assign (ident "b")))
			(e-runtime-error (tag "erroneous_value_expr")))
		(annotation
			(ty-fn (effectful true)
				(ty-apply (name "Shared") (builtin)
					(ty-lookup (name "U64") (builtin)))
				(ty-apply (name "Shared") (builtin)
					(ty-lookup (name "U64") (builtin)))
				(ty-lookup (name "Bool") (builtin))))))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "Shared(U64), Shared(U64) => Bool")))
	(expressions
		(expr (type "Shared(U64), Shared(U64) => Bool"))))
~~~
