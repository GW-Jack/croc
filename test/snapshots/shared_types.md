# META
~~~ini
description=The types of shared state's operations, and an update function's answers
type=snippet
~~~
# SOURCE
~~~roc
take! : Shared(List(a)) => Try(a, [Empty])
take! = |list| list.update!(
	|items| match items {
		[] => Keep(Err(Empty))
		[first, .. as rest] => Set(rest, Ok(first))
	},
)

acquire! : Shared(U64) => {}
acquire! = |permits| permits.update!(|n| if n > 0 Set(n - 1, {}) else Wait)

made! = || Shared.new!("state")

read! = |shared| shared.get!()

effectful! : Shared(U64), (U64 => U64) => {}
effectful! = |shared, f!| shared.modify!(f!)
~~~
# EXPECTED
TYPE MISMATCH - shared_types.md:17:27:17:27
# PROBLEMS
~~~clojure
(reports
	(report
		(severity runtime_error)
		(title "Type Mismatch")
		(region (start 17 42) (end 17 44))
		(headline
			(reflow "The")
			(reflow " ")
			(reflow "first")
			(reflow " ")
			(reflow "argument being passed to this function has the wrong type."))
		(document
			(source-underlines
				(display (file "shared_types.md") (start 17 27) (end 17 45) (annotation dim) (line-text "effectful! = |shared, f!| shared.modify!(f!)"))
				(underline (start 17 42) (end 17 44) (annotation error)))
			(line-break)
			(reflow "This argument has the type:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "U64 => U64")
			(annotation-end)
			(line-break)
			(line-break)
			(reflow "But")
			(reflow " ")
			(annotated code "modify!")
			(reflow " ")
			(reflow "needs the")
			(reflow " ")
			(reflow "first")
			(reflow " ")
			(reflow "argument to be:")
			(line-break)
			(line-break)
			(annotation-start code-block)
			(indent 1)
			(text "U64 -> U64")
			(annotation-end)
			(line-break)
			(line-break)
			(annotated emphasis "Hint:")
			(reflow " ")
			(reflow "This function is effectful, but a pure function is expected."))))
~~~
# TOKENS
~~~zig
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,UpperIdent,NoSpaceOpenRound,LowerIdent,CloseRound,CloseRound,OpFatArrow,UpperIdent,NoSpaceOpenRound,LowerIdent,Comma,OpenSquare,UpperIdent,CloseSquare,CloseRound,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,LowerIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,
OpBar,LowerIdent,OpBar,KwMatch,LowerIdent,OpenCurly,
OpenSquare,CloseSquare,OpFatArrow,UpperIdent,NoSpaceOpenRound,UpperIdent,NoSpaceOpenRound,UpperIdent,CloseRound,CloseRound,
OpenSquare,LowerIdent,Comma,DoubleDot,KwAs,LowerIdent,CloseSquare,OpFatArrow,UpperIdent,NoSpaceOpenRound,LowerIdent,Comma,UpperIdent,NoSpaceOpenRound,LowerIdent,CloseRound,CloseRound,
CloseCurly,Comma,
CloseRound,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,UpperIdent,CloseRound,OpFatArrow,OpenCurly,CloseCurly,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,LowerIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,OpBar,LowerIdent,OpBar,KwIf,LowerIdent,OpGreaterThan,Int,UpperIdent,NoSpaceOpenRound,LowerIdent,OpBinaryMinus,Int,Comma,OpenCurly,CloseCurly,CloseRound,KwElse,UpperIdent,CloseRound,
LowerIdent,OpAssign,OpBar,OpBar,UpperIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,StringStart,StringPart,StringEnd,CloseRound,
LowerIdent,OpAssign,OpBar,LowerIdent,OpBar,LowerIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,CloseRound,
LowerIdent,OpColon,UpperIdent,NoSpaceOpenRound,UpperIdent,CloseRound,Comma,OpenRound,UpperIdent,OpFatArrow,UpperIdent,CloseRound,OpFatArrow,OpenCurly,CloseCurly,
LowerIdent,OpAssign,OpBar,LowerIdent,Comma,LowerIdent,OpBar,LowerIdent,NoSpaceDotLowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,
EndOfFile,
~~~
# PARSE
~~~clojure
(file
	(type-mod)
	(statements
		(s-type-anno (name "take!")
			(ty-fn
				(ty-apply
					(ty (name "Shared"))
					(ty-apply
						(ty (name "List"))
						(ty-var (raw "a"))))
				(ty-apply
					(ty (name "Try"))
					(ty-var (raw "a"))
					(ty-tag-union
						(tags
							(ty (name "Empty")))))))
		(s-decl
			(p-ident (raw "take!"))
			(e-lambda
				(args
					(p-ident (raw "list")))
				(e-method-call (method ".update!")
					(receiver
						(e-ident (raw "list")))
					(args
						(e-lambda
							(args
								(p-ident (raw "items")))
							(e-match
								(e-ident (raw "items"))
								(branches
									(branch
										(p-list)
										(e-apply
											(e-tag (raw "Keep"))
											(e-apply
												(e-tag (raw "Err"))
												(e-tag (raw "Empty")))))
									(branch
										(p-list
											(p-ident (raw "first"))
											(p-list-rest (name "rest")))
										(e-apply
											(e-tag (raw "Set"))
											(e-ident (raw "rest"))
											(e-apply
												(e-tag (raw "Ok"))
												(e-ident (raw "first"))))))))))))
		(s-type-anno (name "acquire!")
			(ty-fn
				(ty-apply
					(ty (name "Shared"))
					(ty (name "U64")))
				(ty-record)))
		(s-decl
			(p-ident (raw "acquire!"))
			(e-lambda
				(args
					(p-ident (raw "permits")))
				(e-method-call (method ".update!")
					(receiver
						(e-ident (raw "permits")))
					(args
						(e-lambda
							(args
								(p-ident (raw "n")))
							(e-if-then-else
								(e-binop (op ">")
									(e-ident (raw "n"))
									(e-int (raw "0")))
								(e-apply
									(e-tag (raw "Set"))
									(e-binop (op "-")
										(e-ident (raw "n"))
										(e-int (raw "1")))
									(e-record))
								(e-tag (raw "Wait"))))))))
		(s-decl
			(p-ident (raw "made!"))
			(e-lambda
				(args)
				(e-apply
					(e-ident (raw "Shared.new!"))
					(e-string
						(e-string-part (raw "state"))))))
		(s-decl
			(p-ident (raw "read!"))
			(e-lambda
				(args
					(p-ident (raw "shared")))
				(e-method-call (method ".get!")
					(receiver
						(e-ident (raw "shared")))
					(args))))
		(s-type-anno (name "effectful!")
			(ty-fn
				(ty-apply
					(ty (name "Shared"))
					(ty (name "U64")))
				(ty-fn
					(ty (name "U64"))
					(ty (name "U64")))
				(ty-record)))
		(s-decl
			(p-ident (raw "effectful!"))
			(e-lambda
				(args
					(p-ident (raw "shared"))
					(p-ident (raw "f!")))
				(e-method-call (method ".modify!")
					(receiver
						(e-ident (raw "shared")))
					(args
						(e-ident (raw "f!"))))))))
~~~
# FORMATTED
~~~roc
take! : Shared(List(a)) => Try(a, [Empty])
take! = |list| list.update!(
	|items| match items {
		[] => Keep(Err(Empty))
		[first, .. as rest] => Set(rest, Ok(first))
	},
)

acquire! : Shared(U64) => {}
acquire! = |permits| permits.update!(|n| if (n > 0) Set(n - 1, {}) else Wait)

made! = || Shared.new!("state")

read! = |shared| shared.get!()

effectful! : Shared(U64), (U64 => U64) => {}
effectful! = |shared, f!| shared.modify!(f!)
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "take!"))
		(e-lambda
			(args
				(p-assign (ident "list")))
			(e-dispatch-call (method "update!") (constraint-fn-var 355)
				(receiver
					(e-lookup-local
						(p-assign (ident "list"))))
				(args
					(e-lambda
						(args
							(p-assign (ident "items")))
						(e-match
							(match
								(cond
									(e-lookup-local
										(p-assign (ident "items"))))
								(branches
									(branch
										(patterns
											(pattern (degenerate false)
												(p-list
													(patterns))))
										(value
											(e-tag (name "Keep")
												(args
													(e-tag (name "Err")
														(args
															(e-tag (name "Empty"))))))))
									(branch
										(patterns
											(pattern (degenerate false)
												(p-list
													(patterns
														(p-assign (ident "first")))
													(rest-at (index 1)
														(p-assign (ident "rest"))))))
										(value
											(e-tag (name "Set")
												(args
													(e-lookup-local
														(p-assign (ident "rest")))
													(e-tag (name "Ok")
														(args
															(e-lookup-local
																(p-assign (ident "first"))))))))))))))))
		(annotation
			(ty-fn (effectful true)
				(ty-apply (name "Shared") (builtin)
					(ty-apply (name "List") (builtin)
						(ty-rigid-var (name "a"))))
				(ty-apply (name "Try") (builtin)
					(ty-rigid-var-lookup (ty-rigid-var (name "a")))
					(ty-tag-union
						(ty-tag-name (name "Empty")))))))
	(d-let
		(p-assign (ident "acquire!"))
		(e-lambda
			(args
				(p-assign (ident "permits")))
			(e-dispatch-call (method "update!") (constraint-fn-var 380)
				(receiver
					(e-lookup-local
						(p-assign (ident "permits"))))
				(args
					(e-lambda
						(args
							(p-assign (ident "n")))
						(e-if
							(if-branches
								(if-branch
									(e-dispatch-call (method "is_gt") (constraint-fn-var 384)
										(receiver
											(e-lookup-local
												(p-assign (ident "n"))))
										(args
											(e-num (value "0"))))
									(e-tag (name "Set")
										(args
											(e-dispatch-call (method "minus") (constraint-fn-var 387)
												(receiver
													(e-lookup-local
														(p-assign (ident "n"))))
												(args
													(e-num (value "1"))))
											(e-empty_record)))))
							(if-else
								(e-tag (name "Wait"))))))))
		(annotation
			(ty-fn (effectful true)
				(ty-apply (name "Shared") (builtin)
					(ty-lookup (name "U64") (builtin)))
				(ty-record))))
	(d-let
		(p-assign (ident "made!"))
		(e-lambda
			(args)
			(e-call (constraint-fn-var 399)
				(e-lookup-external
					(builtin))
				(e-string
					(e-literal (string "state"))))))
	(d-let
		(p-assign (ident "read!"))
		(e-lambda
			(args
				(p-assign (ident "shared")))
			(e-dispatch-call (method "get!") (constraint-fn-var 407)
				(receiver
					(e-lookup-local
						(p-assign (ident "shared"))))
				(args))))
	(d-let
		(p-assign (ident "effectful!"))
		(e-lambda
			(args
				(p-assign (ident "shared"))
				(p-assign (ident "f!")))
			(e-runtime-error (tag "erroneous_value_expr")))
		(annotation
			(ty-fn (effectful true)
				(ty-apply (name "Shared") (builtin)
					(ty-lookup (name "U64") (builtin)))
				(ty-parens
					(ty-fn (effectful true)
						(ty-lookup (name "U64") (builtin))
						(ty-lookup (name "U64") (builtin))))
				(ty-record)))))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "Shared(List(a)) => Try(a, [Empty])"))
		(patt (type "Shared(U64) => {}"))
		(patt (type "() => Shared(state) where [state.from_quote : Str -> Try(state, [BadQuotedBytes(Str)])]"))
		(patt (type "b -> c where [b.get! : b -> c]"))
		(patt (type "Shared(U64), (U64 => U64) => {}")))
	(expressions
		(expr (type "Shared(List(a)) => Try(a, [Empty])"))
		(expr (type "Shared(U64) => {}"))
		(expr (type "() => Shared(state) where [state.from_quote : Str -> Try(state, [BadQuotedBytes(Str)])]"))
		(expr (type "b -> c where [b.get! : b -> c]"))
		(expr (type "Shared(U64), (U64 => U64) => {}"))))
~~~
