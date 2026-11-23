# META
~~~ini
description=a for! source that becomes a Concurrently plan only after the loop is checked keeps the stream protocol, and the missing stream method hints to annotate it
type=file:Loops.roc
~~~
# SOURCE
~~~roc
Loops := [].{
	late! = |plan| {
		for! x in plan {
			_y = x
		}
		check : Concurrently(U64)
		check = plan
		_unused = check
		{}
	}
}
~~~
# EXPECTED
MISSING METHOD - plan_loop_late_source.md:3:13:3:17
# PROBLEMS
~~~clojure
(reports
	(report
		(severity runtime_error)
		(title "Missing Method")
		(region (start 3 13) (end 3 17))
		(headline
			(reflow "This")
			(reflow " ")
			(annotated code "stream")
			(reflow " ")
			(reflow "method is being called on a value whose type doesn't have that method."))
		(document
			(source-region (file "plan_loop_late_source.md") (start 3 13) (end 3 17) (annotation error) (line-text "\t\tfor! x in plan {"))
			(line-break)
			(reflow "The value's type, which does not have a method named ")
			(annotated code "stream")
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
			(reflow "This")
			(reflow " ")
			(annotated code "for!")
			(reflow " ")
			(reflow "loop only learned its source is a")
			(reflow " ")
			(annotated code "Concurrently")
			(reflow " ")
			(reflow "plan after the loop was checked, so it was checked as a loop over a stream. Annotate the source as")
			(reflow " ")
			(annotated code "Concurrently(_)")
			(reflow " ")
			(reflow "so the loop runs it as a plan."))))
~~~
# TOKENS
~~~zig
UpperIdent,OpColonEqual,OpenSquare,CloseSquare,Dot,OpenCurly,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,OpenCurly,
KwForBang,LowerIdent,KwIn,LowerIdent,OpenCurly,
NamedUnderscore,OpAssign,LowerIdent,
CloseCurly,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,UpperIdent,CloseRound,
LowerIdent,OpAssign,LowerIdent,
NamedUnderscore,OpAssign,LowerIdent,
OpenCurly,CloseCurly,
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
				(s-decl
					(p-ident (raw "late!"))
					(e-lambda
						(args
							(p-ident (raw "plan")))
						(e-block
							(statements
								(s-for-bang
									(p-ident (raw "x"))
									(e-ident (raw "plan"))
									(e-block
										(statements
											(s-decl
												(p-ident (raw "_y"))
												(e-ident (raw "x"))))))
								(s-type-anno (name "check")
									(ty-apply
										(ty (name "Concurrently"))
										(ty (name "U64"))))
								(s-decl
									(p-ident (raw "check"))
									(e-ident (raw "plan")))
								(s-decl
									(p-ident (raw "_unused"))
									(e-ident (raw "check")))
								(e-record)))))))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "Loops.late!"))
		(e-lambda
			(args
				(p-assign (ident "plan")))
			(e-block
				(s-for-bang
					(p-assign (ident "x"))
					(e-lookup-local
						(p-assign (ident "plan")))
					(e-block
						(s-let
							(p-assign (ident "_y"))
							(e-lookup-local
								(p-assign (ident "x"))))
						(e-empty_record)))
				(s-let
					(p-assign (ident "check"))
					(e-lookup-local
						(p-assign (ident "plan"))))
				(s-let
					(p-assign (ident "_unused"))
					(e-lookup-local
						(p-assign (ident "check"))))
				(e-empty_record))))
	(s-nominal-decl
		(ty-header (name "Loops"))
		(ty-tag-union)))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "Concurrently(U64) => {}")))
	(type_decls
		(nominal (type "Loops")
			(ty-header (name "Loops"))))
	(expressions
		(expr (type "Concurrently(U64) => {}"))))
~~~
