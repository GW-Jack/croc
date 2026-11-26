# META
~~~ini
description=The Concurrent library's types: all_ok! over functions or a plan whose items are no Try is a type error, and both! and race! infer their results
type=snippet
~~~
# SOURCE
~~~roc
not_try! = || Concurrent.all_ok!([|| 1.U64])

not_try_plan! = || List.concurrently([|| 1.U64]).all_ok!()

pair! = || Concurrent.both!(|| 1.U64, || 2.U8)

winner! : (() => Str) => Str
winner! = |f| Concurrent.race!(f, [|| "b"])

mixed! = || Concurrent.race!(|| 1.U64, [|| 2.U8])

supervised! = || Concurrent.supervise!({ max_restarts: 3 }, || "a")

no_limit! = || Concurrent.supervise!({}, || "a")
~~~
# EXPECTED
TYPE MISMATCH - concurrent_library_types.md:1:34:1:44
TYPE MISMATCH - concurrent_library_types.md:3:20:3:49
TYPE MISMATCH - concurrent_library_types.md:10:30:10:32
TYPE MISMATCH - concurrent_library_types.md:14:38:14:40
# PROBLEMS
~~~clojure
(reports
	(report
		(severity runtime_error)
		(title "Type Mismatch")
		(region (start 1 34) (end 1 44))
		(headline
			(reflow "The")
			(reflow " ")
			(reflow "first")
			(reflow " ")
			(reflow "argument being passed to this function has the wrong type."))
		(document
			(source-region (file "concurrent_library_types.md") (start 1 34) (end 1 44) (annotation error) (line-text "not_try! = || Concurrent.all_ok!([|| 1.U64])"))
			(line-break)
			(reflow "This argument has the type:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "List(() -> U64)")
			(annotation-end)
			(line-break)
			(line-break)
			(reflow "But the function needs the")
			(reflow " ")
			(reflow "first")
			(reflow " ")
			(reflow "argument to be:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "List(() => Try(_ok, _err))")
			(annotation-end)))
	(report
		(severity runtime_error)
		(title "Type Mismatch")
		(region (start 3 20) (end 3 49))
		(headline
			(reflow "The")
			(reflow " ")
			(annotated code "all_ok!")
			(reflow " ")
			(reflow "method on")
			(reflow " ")
			(annotated code "Concurrently")
			(reflow " ")
			(reflow "has an incompatible type."))
		(document
			(source-region (file "concurrent_library_types.md") (start 3 20) (end 3 49) (annotation error) (line-text "not_try_plan! = || List.concurrently([|| 1.U64]).all_ok!()"))
			(line-break)
			(reflow "The method")
			(reflow " ")
			(annotated code "all_ok!")
			(reflow " ")
			(reflow "has the type:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "Concurrently(Try(ok, err)) => Try(List(ok), err)")
			(annotation-end)
			(line-break)
			(line-break)
			(reflow "But I need it to have the type:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "Concurrently(U64) -> _ret")
			(annotation-end)))
	(report
		(severity runtime_error)
		(title "Type Mismatch")
		(region (start 10 30) (end 10 32))
		(headline
			(reflow "The")
			(reflow " ")
			(reflow "first")
			(reflow " ")
			(reflow "and")
			(reflow " ")
			(reflow "second")
			(reflow " ")
			(reflow "arguments")
			(reflow " ")
			(reflow "of this call")
			(reflow " ")
			(reflow "have types that conflict with each other."))
		(document
			(source-region (file "concurrent_library_types.md") (start 10 30) (end 10 32) (annotation error) (line-text "mixed! = || Concurrent.race!(|| 1.U64, [|| 2.U8])"))
			(line-break)
			(reflow "The")
			(reflow " ")
			(reflow "first")
			(reflow " ")
			(reflow "argument")
			(reflow " ")
			(reflow "has the type:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "() => U64")
			(annotation-end)
			(line-break)
			(line-break)
			(source-region (file "concurrent_library_types.md") (start 10 40) (end 10 49) (annotation error) (line-text "mixed! = || Concurrent.race!(|| 1.U64, [|| 2.U8])"))
			(line-break)
			(reflow "But the")
			(reflow " ")
			(reflow "second")
			(reflow " ")
			(reflow "argument")
			(reflow " ")
			(reflow "has the type:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "List(() -> U8)")
			(annotation-end)
			(line-break)
			(line-break)
			(reflow "Each fits the function's type by itself, but that type needs them to agree with each other:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "(() => item), List(() => item) => item")
			(annotation-end)))
	(report
		(severity runtime_error)
		(title "Type Mismatch")
		(region (start 14 38) (end 14 40))
		(headline
			(reflow "The")
			(reflow " ")
			(reflow "first")
			(reflow " ")
			(reflow "argument being passed to this function has the wrong type."))
		(document
			(source-region (file "concurrent_library_types.md") (start 14 38) (end 14 40) (annotation error) (line-text "no_limit! = || Concurrent.supervise!({}, || \"a\")"))
			(line-break)
			(reflow "This argument has the type:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "{}")
			(annotation-end)
			(line-break)
			(line-break)
			(reflow "But the function needs the")
			(reflow " ")
			(reflow "first")
			(reflow " ")
			(reflow "argument to be:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "{ max_restarts: U64 }")
			(annotation-end)
			(line-break)
			(line-break)
			(annotated emphasis "Hint:")
			(reflow " ")
			(reflow "This record is missing the field:")
			(reflow " ")
			(annotated code "max_restarts"))))
~~~
# TOKENS
~~~zig
LowerIdent,OpAssign,OpBar,OpBar,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,OpenSquare,OpBar,OpBar,Int,NoSpaceDotUpperIdent,CloseSquare,CloseRound,
LowerIdent,OpAssign,OpBar,OpBar,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,OpenSquare,OpBar,OpBar,Int,NoSpaceDotUpperIdent,CloseSquare,CloseRound,NoSpaceDotLowerIdent,NoSpaceOpenRound,CloseRound,
LowerIdent,OpAssign,OpBar,OpBar,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,OpBar,OpBar,Int,NoSpaceDotUpperIdent,Comma,OpBar,OpBar,Int,NoSpaceDotUpperIdent,CloseRound,
LowerIdent,OpColon,OpenRound,NoSpaceOpenRound,CloseRound,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,UpperIdent,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,LowerIdent,Comma,OpenSquare,OpBar,OpBar,StringStart,StringPart,StringEnd,CloseSquare,CloseRound,
LowerIdent,OpAssign,OpBar,OpBar,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,OpBar,OpBar,Int,NoSpaceDotUpperIdent,Comma,OpenSquare,OpBar,OpBar,Int,NoSpaceDotUpperIdent,CloseSquare,CloseRound,
LowerIdent,OpAssign,OpBar,OpBar,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,OpenCurly,LowerIdent,OpColon,Int,CloseCurly,Comma,OpBar,OpBar,StringStart,StringPart,StringEnd,CloseRound,
LowerIdent,OpAssign,OpBar,OpBar,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,OpenCurly,CloseCurly,Comma,OpBar,OpBar,StringStart,StringPart,StringEnd,CloseRound,
EndOfFile,
~~~
# PARSE
~~~clojure
(file
	(type-mod)
	(statements
		(s-decl
			(p-ident (raw "not_try!"))
			(e-lambda
				(args)
				(e-apply
					(e-ident (raw "Concurrent.all_ok!"))
					(e-list
						(e-lambda
							(args)
							(e-typed-int (raw "1") (type "U64")))))))
		(s-decl
			(p-ident (raw "not_try_plan!"))
			(e-lambda
				(args)
				(e-method-call (method ".all_ok!")
					(receiver
						(e-apply
							(e-ident (raw "List.concurrently"))
							(e-list
								(e-lambda
									(args)
									(e-typed-int (raw "1") (type "U64"))))))
					(args))))
		(s-decl
			(p-ident (raw "pair!"))
			(e-lambda
				(args)
				(e-apply
					(e-ident (raw "Concurrent.both!"))
					(e-lambda
						(args)
						(e-typed-int (raw "1") (type "U64")))
					(e-lambda
						(args)
						(e-typed-int (raw "2") (type "U8"))))))
		(s-type-anno (name "winner!")
			(ty-fn
				(ty-fn
					(ty (name "Str")))
				(ty (name "Str"))))
		(s-decl
			(p-ident (raw "winner!"))
			(e-lambda
				(args
					(p-ident (raw "f")))
				(e-apply
					(e-ident (raw "Concurrent.race!"))
					(e-ident (raw "f"))
					(e-list
						(e-lambda
							(args)
							(e-string
								(e-string-part (raw "b"))))))))
		(s-decl
			(p-ident (raw "mixed!"))
			(e-lambda
				(args)
				(e-apply
					(e-ident (raw "Concurrent.race!"))
					(e-lambda
						(args)
						(e-typed-int (raw "1") (type "U64")))
					(e-list
						(e-lambda
							(args)
							(e-typed-int (raw "2") (type "U8")))))))
		(s-decl
			(p-ident (raw "supervised!"))
			(e-lambda
				(args)
				(e-apply
					(e-ident (raw "Concurrent.supervise!"))
					(e-record
						(field (field "max_restarts")
							(e-int (raw "3"))))
					(e-lambda
						(args)
						(e-string
							(e-string-part (raw "a")))))))
		(s-decl
			(p-ident (raw "no_limit!"))
			(e-lambda
				(args)
				(e-apply
					(e-ident (raw "Concurrent.supervise!"))
					(e-record)
					(e-lambda
						(args)
						(e-string
							(e-string-part (raw "a")))))))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "not_try!"))
		(e-lambda
			(args)
			(e-runtime-error (tag "erroneous_value_expr"))))
	(d-let
		(p-assign (ident "not_try_plan!"))
		(e-lambda
			(args)
			(e-runtime-error (tag "erroneous_value_expr")
				(e-call (constraint-fn-var 344)
					(e-lookup-external
						(builtin))
					(e-list
						(elems
							(e-lambda
								(args)
								(e-typed-int (value "1") (type "U64")))))))))
	(d-let
		(p-assign (ident "pair!"))
		(e-lambda
			(args)
			(e-call (constraint-fn-var 371)
				(e-lookup-external
					(builtin))
				(e-lambda
					(args)
					(e-typed-int (value "1") (type "U64")))
				(e-lambda
					(args)
					(e-typed-int (value "2") (type "U8"))))))
	(d-let
		(p-assign (ident "winner!"))
		(e-lambda
			(args
				(p-assign (ident "f")))
			(e-call (constraint-fn-var 385)
				(e-lookup-external
					(builtin))
				(e-lookup-local
					(p-assign (ident "f")))
				(e-list
					(elems
						(e-lambda
							(args)
							(e-string
								(e-literal (string "b"))))))))
		(annotation
			(ty-fn (effectful true)
				(ty-parens
					(ty-fn (effectful true)
						(ty-lookup (name "Str") (builtin))))
				(ty-lookup (name "Str") (builtin)))))
	(d-let
		(p-assign (ident "mixed!"))
		(e-lambda
			(args)
			(e-runtime-error (tag "erroneous_value_expr"))))
	(d-let
		(p-assign (ident "supervised!"))
		(e-lambda
			(args)
			(e-call (constraint-fn-var 405)
				(e-lookup-external
					(builtin))
				(e-record
					(fields
						(field (name "max_restarts")
							(e-num (value "3")))))
				(e-lambda
					(args)
					(e-string
						(e-literal (string "a")))))))
	(d-let
		(p-assign (ident "no_limit!"))
		(e-lambda
			(args)
			(e-runtime-error (tag "erroneous_value_expr")))))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "() -> _ret"))
		(patt (type "() -> _ret"))
		(patt (type "() => (U64, U8)"))
		(patt (type "(() => Str) => Str"))
		(patt (type "() -> _ret"))
		(patt (type "() => item where [item.from_quote : Str -> Try(item, [BadQuotedBytes(Str)])]"))
		(patt (type "() -> _ret")))
	(expressions
		(expr (type "() -> _ret"))
		(expr (type "() -> _ret"))
		(expr (type "() => (U64, U8)"))
		(expr (type "(() => Str) => Str"))
		(expr (type "() -> _ret"))
		(expr (type "() => item where [item.from_quote : Str -> Try(item, [BadQuotedBytes(Str)])]"))
		(expr (type "() -> _ret"))))
~~~
