# META
~~~ini
description=Only the compiler may call or name a Concurrently running-set helper
type=file:Helpers.roc
~~~
# SOURCE
~~~roc
Helpers := [].{
	entry! : (() => U64) => U64
	entry! = |f| Concurrently.run_entry!(f)

	named! : (() => U64) => U64
	named! = Concurrently.run_entry!

	supervised! : (() => U64) => U64
	supervised! = |f| Concurrently.run_supervised!(1, f)

	flat : List(() => U64) -> List(Bool)
	flat = |fs| List.concurrently(fs).flatten().background
}
~~~
# EXPECTED
COMPILER ONLY FUNCTION - running_set_helper_use.md:3:15:3:38
COMPILER ONLY FUNCTION - running_set_helper_use.md:6:11:6:34
COMPILER ONLY FUNCTION - running_set_helper_use.md:9:20:9:48
# PROBLEMS
~~~clojure
(reports
	(report
		(severity runtime_error)
		(title "Compiler Only Function")
		(region (start 3 15) (end 3 38))
		(headline
			(reflow "This uses a function only the compiler may call."))
		(document
			(source-region (file "running_set_helper_use.md") (start 3 15) (end 3 38) (annotation error) (line-text "\tentry! = |f| Concurrently.run_entry!(f)"))
			(line-break)
			(line-break)
			(reflow "The running-set functions of `Concurrently` run `for!` loops over plans, supervised functions and waits on shared state, and only the compiler calls them. This use crashes if it runs.")))
	(report
		(severity runtime_error)
		(title "Compiler Only Function")
		(region (start 6 11) (end 6 34))
		(headline
			(reflow "This uses a function only the compiler may call."))
		(document
			(source-region (file "running_set_helper_use.md") (start 6 11) (end 6 34) (annotation error) (line-text "\tnamed! = Concurrently.run_entry!"))
			(line-break)
			(line-break)
			(reflow "The running-set functions of `Concurrently` run `for!` loops over plans, supervised functions and waits on shared state, and only the compiler calls them. This use crashes if it runs.")))
	(report
		(severity runtime_error)
		(title "Compiler Only Function")
		(region (start 9 20) (end 9 48))
		(headline
			(reflow "This uses a function only the compiler may call."))
		(document
			(source-region (file "running_set_helper_use.md") (start 9 20) (end 9 48) (annotation error) (line-text "\tsupervised! = |f| Concurrently.run_supervised!(1, f)"))
			(line-break)
			(line-break)
			(reflow "The running-set functions of `Concurrently` run `for!` loops over plans, supervised functions and waits on shared state, and only the compiler calls them. This use crashes if it runs."))))
~~~
# TOKENS
~~~zig
UpperIdent,OpColonEqual,OpenSquare,CloseSquare,Dot,OpenCurly,
LowerIdent,OpColon,OpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,UpperIdent,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,
LowerIdent,OpColon,OpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,UpperIdent,
LowerIdent,OpAssign,UpperIdent,NoSpaceDotLowerIdent,
LowerIdent,OpColon,OpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,UpperIdent,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,Int,Comma,LowerIdent,CloseRound,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpArrow,UpperIdent,NoSpaceOpenRound,UpperIdent,CloseRound,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,NoSpaceDotLowerIdent,NoSpaceOpenRound,CloseRound,NoSpaceDotLowerIdent,
CloseCurly,
EndOfFile,
~~~
# PARSE
~~~clojure
(file
	(type-mod)
	(statements
		(s-type-decl
			(header (name "Helpers")
				(args))
			(ty-tag-union
				(tags))
			(associated
				(s-type-anno (name "entry!")
					(ty-fn
						(ty-fn
							(ty (name "U64")))
						(ty (name "U64"))))
				(s-decl
					(p-ident (raw "entry!"))
					(e-lambda
						(args
							(p-ident (raw "f")))
						(e-apply
							(e-ident (raw "Concurrently.run_entry!"))
							(e-ident (raw "f")))))
				(s-type-anno (name "named!")
					(ty-fn
						(ty-fn
							(ty (name "U64")))
						(ty (name "U64"))))
				(s-decl
					(p-ident (raw "named!"))
					(e-ident (raw "Concurrently.run_entry!")))
				(s-type-anno (name "supervised!")
					(ty-fn
						(ty-fn
							(ty (name "U64")))
						(ty (name "U64"))))
				(s-decl
					(p-ident (raw "supervised!"))
					(e-lambda
						(args
							(p-ident (raw "f")))
						(e-apply
							(e-ident (raw "Concurrently.run_supervised!"))
							(e-int (raw "1"))
							(e-ident (raw "f")))))
				(s-type-anno (name "flat")
					(ty-fn
						(ty-apply
							(ty (name "List"))
							(ty-fn
								(ty (name "U64"))))
						(ty-apply
							(ty (name "List"))
							(ty (name "Bool")))))
				(s-decl
					(p-ident (raw "flat"))
					(e-lambda
						(args
							(p-ident (raw "fs")))
						(e-field-access
							(receiver
								(e-method-call (method ".flatten")
									(receiver
										(e-apply
											(e-ident (raw "List.concurrently"))
											(e-ident (raw "fs"))))
									(args)))
							(segment (mode "required") (field "background")))))))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "Helpers.entry!"))
		(e-lambda
			(args
				(p-assign (ident "f")))
			(e-runtime-error (tag "erroneous_value_expr")))
		(annotation
			(ty-fn (effectful true)
				(ty-parens
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-lookup (name "U64") (builtin)))))
	(d-let
		(p-assign (ident "Helpers.named!"))
		(e-runtime-error (tag "erroneous_value_expr"))
		(annotation
			(ty-fn (effectful true)
				(ty-parens
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-lookup (name "U64") (builtin)))))
	(d-let
		(p-assign (ident "Helpers.supervised!"))
		(e-lambda
			(args
				(p-assign (ident "f")))
			(e-runtime-error (tag "erroneous_value_expr")))
		(annotation
			(ty-fn (effectful true)
				(ty-parens
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-lookup (name "U64") (builtin)))))
	(d-let
		(p-assign (ident "Helpers.flat"))
		(e-lambda
			(args
				(p-assign (ident "fs")))
			(e-field-access
				(receiver
					(e-dispatch-call (method "flatten") (constraint-fn-var 426)
						(receiver
							(e-call (constraint-fn-var 424)
								(e-lookup-external
									(builtin))
								(e-lookup-local
									(p-assign (ident "fs")))))
						(args)))
				(segments
					(segment (name "background") (mode "required")))))
		(annotation
			(ty-fn (effectful false)
				(ty-apply (name "List") (builtin)
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))))
				(ty-apply (name "List") (builtin)
					(ty-lookup (name "Bool") (builtin))))))
	(s-nominal-decl
		(ty-header (name "Helpers"))
		(ty-tag-union)))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "(() => U64) => U64"))
		(patt (type "(() => U64) => U64"))
		(patt (type "(() => U64) => U64"))
		(patt (type "List(() => U64) -> List(Bool)")))
	(type_decls
		(nominal (type "Helpers")
			(ty-header (name "Helpers"))))
	(expressions
		(expr (type "(() => U64) => U64"))
		(expr (type "(() => U64) => U64"))
		(expr (type "(() => U64) => U64"))
		(expr (type "List(() => U64) -> List(Bool)"))))
~~~
