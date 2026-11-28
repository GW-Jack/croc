# META
~~~ini
description=spawn's operand must be a zero-argument effectful function returning the plan loop's item type
type=file:Loops.roc
~~~
# SOURCE
~~~roc
Loops := [].{
	not_a_function! : List(() => U64) => {}
	not_a_function! = |fs| {
		for! x in List.concurrently(fs) {
			spawn x
		}
	}

	wrong_item! : List(() => U64), (() => Str) => {}
	wrong_item! = |fs, f| {
		for! _x in List.concurrently(fs) {
			spawn f
		}
	}

	takes_argument! : List(() => U64), (U64 => U64) => {}
	takes_argument! = |fs, f| {
		for! _x in List.concurrently(fs) {
			spawn f
		}
	}
}
~~~
# EXPECTED
TYPE MISMATCH - spawn_type_mismatch.md:5:10:5:11
TYPE MISMATCH - spawn_type_mismatch.md:12:10:12:11
TYPE MISMATCH - spawn_type_mismatch.md:19:10:19:11
# PROBLEMS
~~~clojure
(reports
	(report
		(severity runtime_error)
		(title "Type Mismatch")
		(region (start 5 10) (end 5 11))
		(headline
			(reflow "This expression is used in an unexpected way."))
		(document
			(source-region (file "spawn_type_mismatch.md") (start 5 10) (end 5 11) (annotation error) (line-text "\t\t\tspawn x"))
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
			(reflow "But you are trying to use it as:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "() => U64")
			(annotation-end)))
	(report
		(severity runtime_error)
		(title "Type Mismatch")
		(region (start 12 10) (end 12 11))
		(headline
			(reflow "This expression is used in an unexpected way."))
		(document
			(source-region (file "spawn_type_mismatch.md") (start 12 10) (end 12 11) (annotation error) (line-text "\t\t\tspawn f"))
			(line-break)
			(reflow "It has the type:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "() => Str")
			(annotation-end)
			(line-break)
			(line-break)
			(reflow "But you are trying to use it as:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "() => U64")
			(annotation-end)))
	(report
		(severity runtime_error)
		(title "Type Mismatch")
		(region (start 19 10) (end 19 11))
		(headline
			(reflow "This expression is used in an unexpected way."))
		(document
			(source-region (file "spawn_type_mismatch.md") (start 19 10) (end 19 11) (annotation error) (line-text "\t\t\tspawn f"))
			(line-break)
			(reflow "It has the type:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "U64 => U64")
			(annotation-end)
			(line-break)
			(line-break)
			(reflow "But you are trying to use it as:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "() => U64")
			(annotation-end)
			(line-break)
			(line-break)
			(annotated emphasis "Hint:")
			(reflow " ")
			(reflow "This function expects")
			(reflow " ")
			(reflow "0")
			(reflow " ")
			(reflow "arguments")
			(reflow " ")
			(reflow "but got")
			(reflow " ")
			(reflow "1")
			(reflow "."))))
~~~
# TOKENS
~~~zig
UpperIdent,OpColonEqual,OpenSquare,CloseSquare,Dot,OpenCurly,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,OpenCurly,CloseCurly,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,OpenCurly,
KwForBang,LowerIdent,KwIn,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,OpenCurly,
LowerIdent,LowerIdent,
CloseCurly,
CloseCurly,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,Comma,OpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,OpenCurly,CloseCurly,
LowerIdent,OpAssign,OpBar,LowerIdent,Comma,LowerIdent,OpBar,OpenCurly,
KwForBang,NamedUnderscore,KwIn,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,OpenCurly,
LowerIdent,LowerIdent,
CloseCurly,
CloseCurly,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,Comma,OpenRound,UpperIdent,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,OpenCurly,CloseCurly,
LowerIdent,OpAssign,OpBar,LowerIdent,Comma,LowerIdent,OpBar,OpenCurly,
KwForBang,NamedUnderscore,KwIn,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,OpenCurly,
LowerIdent,LowerIdent,
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
				(s-type-anno (name "not_a_function!")
					(ty-fn
						(ty-apply
							(ty (name "List"))
							(ty-fn
								(ty (name "U64"))))
						(ty-record)))
				(s-decl
					(p-ident (raw "not_a_function!"))
					(e-lambda
						(args
							(p-ident (raw "fs")))
						(e-block
							(statements
								(s-for-bang
									(p-ident (raw "x"))
									(e-apply
										(e-ident (raw "List.concurrently"))
										(e-ident (raw "fs")))
									(e-block
										(statements
											(e-spawn
												(e-ident (raw "x"))))))))))
				(s-type-anno (name "wrong_item!")
					(ty-fn
						(ty-apply
							(ty (name "List"))
							(ty-fn
								(ty (name "U64"))))
						(ty-fn
							(ty (name "Str")))
						(ty-record)))
				(s-decl
					(p-ident (raw "wrong_item!"))
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
											(e-spawn
												(e-ident (raw "f"))))))))))
				(s-type-anno (name "takes_argument!")
					(ty-fn
						(ty-apply
							(ty (name "List"))
							(ty-fn
								(ty (name "U64"))))
						(ty-fn
							(ty (name "U64"))
							(ty (name "U64")))
						(ty-record)))
				(s-decl
					(p-ident (raw "takes_argument!"))
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
											(e-spawn
												(e-ident (raw "f"))))))))))))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "Loops.not_a_function!"))
		(e-lambda
			(args
				(p-assign (ident "fs")))
			(e-block
				(s-for-bang
					(p-assign (ident "x"))
					(e-call (constraint-fn-var 419)
						(e-lookup-external
							(builtin))
						(e-lookup-local
							(p-assign (ident "fs"))))
					(e-block
						(s-expr
							(e-runtime-error (tag "erroneous_value_expr")))
						(e-empty_record)))
				(e-empty_record)))
		(annotation
			(ty-fn (effectful true)
				(ty-apply (name "List") (builtin)
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-record))))
	(d-let
		(p-assign (ident "Loops.wrong_item!"))
		(e-lambda
			(args
				(p-assign (ident "fs"))
				(p-assign (ident "f")))
			(e-block
				(s-for-bang
					(p-assign (ident "_x"))
					(e-call (constraint-fn-var 525)
						(e-lookup-external
							(builtin))
						(e-lookup-local
							(p-assign (ident "fs"))))
					(e-block
						(s-expr
							(e-runtime-error (tag "erroneous_value_expr")))
						(e-empty_record)))
				(e-empty_record)))
		(annotation
			(ty-fn (effectful true)
				(ty-apply (name "List") (builtin)
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-parens
					(ty-fn (effectful true)
						(ty-lookup (name "Str") (builtin))))
				(ty-record))))
	(d-let
		(p-assign (ident "Loops.takes_argument!"))
		(e-lambda
			(args
				(p-assign (ident "fs"))
				(p-assign (ident "f")))
			(e-block
				(s-for-bang
					(p-assign (ident "_x"))
					(e-call (constraint-fn-var 579)
						(e-lookup-external
							(builtin))
						(e-lookup-local
							(p-assign (ident "fs"))))
					(e-block
						(s-expr
							(e-runtime-error (tag "erroneous_value_expr")))
						(e-empty_record)))
				(e-empty_record)))
		(annotation
			(ty-fn (effectful true)
				(ty-apply (name "List") (builtin)
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-parens
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))
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
		(patt (type "List(() => U64) => {}"))
		(patt (type "List(() => U64), (() => Str) => {}"))
		(patt (type "List(() => U64), (U64 => U64) => {}")))
	(type_decls
		(nominal (type "Loops")
			(ty-header (name "Loops"))))
	(expressions
		(expr (type "List(() => U64) => {}"))
		(expr (type "List(() => U64), (() => Str) => {}"))
		(expr (type "List(() => U64), (U64 => U64) => {}"))))
~~~
