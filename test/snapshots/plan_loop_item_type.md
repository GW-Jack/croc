# META
~~~ini
description=for! over a Concurrently plan, built directly or by method, binds the plan's item type
type=file:Loops.roc
~~~
# SOURCE
~~~roc
Loops := [].{
	direct! : List(() => U64) => U64
	direct! = |fs| {
		var $sum = 0
		for! x in List.concurrently(fs) {
			$sum = $sum + x
		}
		$sum
	}

	method! : List(() => U64) => U64
	method! = |fs| {
		var $sum = 0
		for! x in fs.concurrently().limit(2) {
			$sum = $sum + x
		}
		$sum
	}

	item_typed! : List(() => U64) => Str
	item_typed! = |fs| {
		var $s = ""
		for! x in List.concurrently(fs) {
			$s = x
		}
		$s
	}
}
~~~
# EXPECTED
TYPE MISMATCH - plan_loop_item_type.md:22:12:22:14
TYPE MISMATCH - plan_loop_item_type.md:26:3:26:5
# PROBLEMS
~~~clojure
(reports
	(report
		(severity runtime_error)
		(title "Type Mismatch")
		(region (start 22 12) (end 22 14))
		(headline
			(reflow "This string literal is being used where a non-string type is needed."))
		(document
			(source-region (file "plan_loop_item_type.md") (start 22 12) (end 22 14) (annotation error) (line-text "\t\tvar $s = \"\""))
			(line-break)
			(reflow "The type was determined to be:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "U64")
			(annotation-end)))
	(report
		(severity runtime_error)
		(title "Type Mismatch")
		(region (start 26 3) (end 26 5))
		(headline
			(reflow "This expression is used in an unexpected way."))
		(document
			(source-region (file "plan_loop_item_type.md") (start 26 3) (end 26 5) (annotation error) (line-text "\t\t$s"))
			(line-break)
			(reflow "It has the type:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "U64")
			(annotation-end)
			(line-break)
			(line-break)
			(reflow "But the annotation says it should be:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "Str")
			(annotation-end)
			(line-break)
			(line-break)
			(annotated emphasis "Hint:")
			(reflow " ")
			(reflow "Convert it to a")
			(reflow " ")
			(annotated code "Str")
			(reflow " ")
			(reflow "with")
			(reflow " ")
			(annotated code ".to_str()")
			(reflow "."))))
~~~
# TOKENS
~~~zig
UpperIdent,OpColonEqual,OpenSquare,CloseSquare,Dot,OpenCurly,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,UpperIdent,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,OpenCurly,
KwVar,LowerIdent,OpAssign,Int,
KwForBang,LowerIdent,KwIn,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,OpenCurly,
LowerIdent,OpAssign,LowerIdent,OpPlus,LowerIdent,
CloseCurly,
LowerIdent,
CloseCurly,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,UpperIdent,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,OpenCurly,
KwVar,LowerIdent,OpAssign,Int,
KwForBang,LowerIdent,KwIn,LowerIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,CloseRound,NoSpaceDotLowerIdent,NoSpaceOpenRound,Int,CloseRound,OpenCurly,
LowerIdent,OpAssign,LowerIdent,OpPlus,LowerIdent,
CloseCurly,
LowerIdent,
CloseCurly,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,UpperIdent,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,OpenCurly,
KwVar,LowerIdent,OpAssign,StringStart,StringPart,StringEnd,
KwForBang,LowerIdent,KwIn,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,OpenCurly,
LowerIdent,OpAssign,LowerIdent,
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
						(ty (name "U64"))))
				(s-decl
					(p-ident (raw "direct!"))
					(e-lambda
						(args
							(p-ident (raw "fs")))
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
											(s-decl
												(p-ident (raw "$sum"))
												(e-binop (op "+")
													(e-ident (raw "$sum"))
													(e-ident (raw "x")))))))
								(e-ident (raw "$sum"))))))
				(s-type-anno (name "method!")
					(ty-fn
						(ty-apply
							(ty (name "List"))
							(ty-fn
								(ty (name "U64"))))
						(ty (name "U64"))))
				(s-decl
					(p-ident (raw "method!"))
					(e-lambda
						(args
							(p-ident (raw "fs")))
						(e-block
							(statements
								(s-var (name "$sum")
									(e-int (raw "0")))
								(s-for-bang
									(p-ident (raw "x"))
									(e-method-call (method ".limit")
										(receiver
											(e-method-call (method ".concurrently")
												(receiver
													(e-ident (raw "fs")))
												(args)))
										(args
											(e-int (raw "2"))))
									(e-block
										(statements
											(s-decl
												(p-ident (raw "$sum"))
												(e-binop (op "+")
													(e-ident (raw "$sum"))
													(e-ident (raw "x")))))))
								(e-ident (raw "$sum"))))))
				(s-type-anno (name "item_typed!")
					(ty-fn
						(ty-apply
							(ty (name "List"))
							(ty-fn
								(ty (name "U64"))))
						(ty (name "Str"))))
				(s-decl
					(p-ident (raw "item_typed!"))
					(e-lambda
						(args
							(p-ident (raw "fs")))
						(e-block
							(statements
								(s-var (name "$s")
									(e-string
										(e-string-part (raw ""))))
								(s-for-bang
									(p-ident (raw "x"))
									(e-apply
										(e-ident (raw "List.concurrently"))
										(e-ident (raw "fs")))
									(e-block
										(statements
											(s-decl
												(p-ident (raw "$s"))
												(e-ident (raw "x"))))))
								(e-ident (raw "$s"))))))))))
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
				(p-assign (ident "fs")))
			(e-block
				(s-var
					(p-var-assign (ident "$sum"))
					(e-num (value "0")))
				(s-for-bang
					(p-assign (ident "x"))
					(e-call (constraint-fn-var 347)
						(e-lookup-external
							(builtin))
						(e-lookup-local
							(p-assign (ident "fs"))))
					(e-block
						(s-reassign
							(p-var-assign (ident "$sum"))
							(e-dispatch-call (method "plus") (constraint-fn-var 484)
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
				(ty-lookup (name "U64") (builtin)))))
	(d-let
		(p-assign (ident "Loops.method!"))
		(e-lambda
			(args
				(p-assign (ident "fs")))
			(e-block
				(s-var
					(p-var-assign (ident "$sum"))
					(e-num (value "0")))
				(s-for-bang
					(p-assign (ident "x"))
					(e-dispatch-call (method "limit") (constraint-fn-var 500)
						(receiver
							(e-dispatch-call (method "concurrently") (constraint-fn-var 491)
								(receiver
									(e-lookup-local
										(p-assign (ident "fs"))))
								(args)))
						(args
							(e-num (value "2"))))
					(e-block
						(s-reassign
							(p-var-assign (ident "$sum"))
							(e-dispatch-call (method "plus") (constraint-fn-var 484)
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
				(ty-lookup (name "U64") (builtin)))))
	(d-let
		(p-assign (ident "Loops.item_typed!"))
		(e-lambda
			(args
				(p-assign (ident "fs")))
			(e-block
				(s-var
					(p-var-assign (ident "$s"))
					(e-runtime-error (tag "erroneous_value_expr")))
				(s-for-bang
					(p-assign (ident "x"))
					(e-call (constraint-fn-var 609)
						(e-lookup-external
							(builtin))
						(e-lookup-local
							(p-assign (ident "fs"))))
					(e-block
						(s-reassign
							(p-var-assign (ident "$s"))
							(e-lookup-local
								(p-assign (ident "x"))))
						(e-empty_record)))
				(e-runtime-error (tag "erroneous_value_expr"))))
		(annotation
			(ty-fn (effectful true)
				(ty-apply (name "List") (builtin)
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-lookup (name "Str") (builtin)))))
	(s-nominal-decl
		(ty-header (name "Loops"))
		(ty-tag-union)))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "List(() => U64) => U64"))
		(patt (type "List(() => U64) => U64"))
		(patt (type "List(() => U64) => Str")))
	(type_decls
		(nominal (type "Loops")
			(ty-header (name "Loops"))))
	(expressions
		(expr (type "List(() => U64) => U64"))
		(expr (type "List(() => U64) => U64"))
		(expr (type "List(() => U64) => Str"))))
~~~
