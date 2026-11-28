# META
~~~ini
description=a pure for loop over a Concurrently plan is a missing iter method, with a hint to use for!
type=file:Loops.roc
~~~
# SOURCE
~~~roc
Loops := [].{
	plain : List(() => U64) -> U64
	plain = |fs| {
		var $sum = 0
		for x in List.concurrently(fs) {
			$sum = $sum + x
		}
		$sum
	}
}
~~~
# EXPECTED
MISSING METHOD - plan_loop_plain_for.md:5:12:5:33
# PROBLEMS
~~~clojure
(reports
	(report
		(severity runtime_error)
		(title "Missing Method")
		(region (start 5 12) (end 5 33))
		(headline
			(reflow "This")
			(reflow " ")
			(annotated code "iter")
			(reflow " ")
			(reflow "method is being called on a value whose type doesn't have that method."))
		(document
			(source-region (file "plan_loop_plain_for.md") (start 5 12) (end 5 33) (annotation error) (line-text "\t\tfor x in List.concurrently(fs) {"))
			(line-break)
			(reflow "The value's type, which does not have a method named ")
			(annotated code "iter")
			(reflow ",")
			(reflow " ")
			(reflow "is:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "Concurrently(U64)")
			(annotation-end)
			(line-break)
			(line-break)
			(annotated emphasis "Hint:")
			(reflow " ")
			(reflow "A")
			(reflow " ")
			(annotated code "Concurrently")
			(reflow " ")
			(reflow "plan runs with")
			(reflow " ")
			(annotated code "for!")
			(reflow ", not")
			(reflow " ")
			(annotated code "for")
			(reflow "."))))
~~~
# TOKENS
~~~zig
UpperIdent,OpColonEqual,OpenSquare,CloseSquare,Dot,OpenCurly,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpArrow,UpperIdent,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,OpenCurly,
KwVar,LowerIdent,OpAssign,Int,
KwFor,LowerIdent,KwIn,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,OpenCurly,
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
				(s-type-anno (name "plain")
					(ty-fn
						(ty-apply
							(ty (name "List"))
							(ty-fn
								(ty (name "U64"))))
						(ty (name "U64"))))
				(s-decl
					(p-ident (raw "plain"))
					(e-lambda
						(args
							(p-ident (raw "fs")))
						(e-block
							(statements
								(s-var (name "$sum")
									(e-int (raw "0")))
								(s-for
									(p-ident (raw "x"))
									(e-apply
										(e-ident (raw "List.concurrently"))
										(e-ident (raw "fs")))
									(e-block
										(statements
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
		(p-assign (ident "Loops.plain"))
		(e-lambda
			(args
				(p-assign (ident "fs")))
			(e-block
				(s-var
					(p-var-assign (ident "$sum"))
					(e-num (value "0")))
				(s-for
					(p-assign (ident "x"))
					(e-call (constraint-fn-var 347)
						(e-lookup-external
							(builtin))
						(e-lookup-local
							(p-assign (ident "fs"))))
					(e-block
						(s-reassign
							(p-var-assign (ident "$sum"))
							(e-dispatch-call (method "plus") (constraint-fn-var 372)
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
			(ty-fn (effectful false)
				(ty-apply (name "List") (builtin)
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-lookup (name "U64") (builtin)))))
	(s-nominal-decl
		(ty-header (name "Loops"))
		(ty-tag-union)))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "List(() => U64) -> U64")))
	(type_decls
		(nominal (type "Loops")
			(ty-header (name "Loops"))))
	(expressions
		(expr (type "List(() => U64) -> U64"))))
~~~
