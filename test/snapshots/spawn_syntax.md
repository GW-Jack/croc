# META
~~~ini
description=spawn's operand forms parse and format, and a match arm body can be a spawn
type=statement
~~~
# SOURCE
~~~roc
for! link in links {
	spawn   fetch
	spawn ||   x!()
	spawn  (f)
	spawn if a { f } else { g }
	spawn match link { Some(l) => make(l), None => g }
	spawn Pkg.f
	match link {
		Ok(v) =>   spawn make(v)
		Err(_) => {}
	}
}
~~~
# EXPECTED
NIL
# PROBLEMS
NIL
# TOKENS
~~~zig
KwForBang,LowerIdent,KwIn,LowerIdent,OpenCurly,
LowerIdent,LowerIdent,
LowerIdent,OpBar,OpBar,LowerIdent,NoSpaceOpenRound,CloseRound,
LowerIdent,OpenRound,LowerIdent,CloseRound,
LowerIdent,KwIf,LowerIdent,OpenCurly,LowerIdent,CloseCurly,KwElse,OpenCurly,LowerIdent,CloseCurly,
LowerIdent,KwMatch,LowerIdent,OpenCurly,UpperIdent,NoSpaceOpenRound,LowerIdent,CloseRound,OpFatArrow,LowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,Comma,UpperIdent,OpFatArrow,LowerIdent,CloseCurly,
LowerIdent,UpperIdent,NoSpaceDotLowerIdent,
KwMatch,LowerIdent,OpenCurly,
UpperIdent,NoSpaceOpenRound,LowerIdent,CloseRound,OpFatArrow,LowerIdent,LowerIdent,NoSpaceOpenRound,LowerIdent,CloseRound,
UpperIdent,NoSpaceOpenRound,Underscore,CloseRound,OpFatArrow,OpenCurly,CloseCurly,
CloseCurly,
CloseCurly,
EndOfFile,
~~~
# PARSE
~~~clojure
(s-for-bang
	(p-ident (raw "link"))
	(e-ident (raw "links"))
	(e-block
		(statements
			(e-spawn
				(e-ident (raw "fetch")))
			(e-spawn
				(e-lambda
					(args)
					(e-apply
						(e-ident (raw "x!")))))
			(e-spawn
				(e-tuple
					(e-ident (raw "f"))))
			(e-spawn
				(e-if-then-else
					(e-ident (raw "a"))
					(e-block
						(statements
							(e-ident (raw "f"))))
					(e-block
						(statements
							(e-ident (raw "g"))))))
			(e-spawn
				(e-match
					(e-ident (raw "link"))
					(branches
						(branch
							(p-tag (raw "Some")
								(p-ident (raw "l")))
							(e-apply
								(e-ident (raw "make"))
								(e-ident (raw "l"))))
						(branch
							(p-tag (raw "None"))
							(e-ident (raw "g"))))))
			(e-spawn
				(e-ident (raw "Pkg.f")))
			(e-match
				(e-ident (raw "link"))
				(branches
					(branch
						(p-tag (raw "Ok")
							(p-ident (raw "v")))
						(e-spawn
							(e-apply
								(e-ident (raw "make"))
								(e-ident (raw "v")))))
					(branch
						(p-tag (raw "Err")
							(p-underscore))
						(e-record)))))))
~~~
# FORMATTED
~~~roc
for! link in links {
	spawn fetch
	spawn || x!()
	spawn (f)
	spawn if a {
		f
	} else {
		g
	}
	spawn match link {
		Some(l) => make(l)
		None => g
	}
	spawn Pkg.f
	match link {
		Ok(v) => spawn make(v)
		Err(_) => {}
	}
}
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(s-for-bang
		(p-assign (ident "link"))
		(e-runtime-error (tag "ident_not_in_scope"))
		(e-block
			(s-expr
				(e-spawn
					(e-runtime-error (tag "ident_not_in_scope"))))
			(s-expr
				(e-spawn
					(e-lambda
						(args)
						(e-call
							(e-runtime-error (tag "ident_not_in_scope"))))))
			(s-expr
				(e-spawn
					(e-runtime-error (tag "ident_not_in_scope"))))
			(s-expr
				(e-spawn
					(e-if
						(if-branches
							(if-branch
								(e-runtime-error (tag "ident_not_in_scope"))
								(e-block
									(e-runtime-error (tag "ident_not_in_scope")))))
						(if-else
							(e-block
								(e-runtime-error (tag "ident_not_in_scope")))))))
			(s-expr
				(e-spawn
					(e-match
						(match
							(cond
								(e-lookup-local
									(p-assign (ident "link"))))
							(branches
								(branch
									(patterns
										(pattern (degenerate false)
											(p-applied-tag)))
									(value
										(e-call
											(e-runtime-error (tag "ident_not_in_scope"))
											(e-lookup-local
												(p-assign (ident "l"))))))
								(branch
									(patterns
										(pattern (degenerate false)
											(p-applied-tag)))
									(value
										(e-runtime-error (tag "ident_not_in_scope")))))))))
			(s-expr
				(e-spawn
					(e-runtime-error (tag "qualified_ident_does_not_exist"))))
			(s-expr
				(e-match
					(match
						(cond
							(e-lookup-local
								(p-assign (ident "link"))))
						(branches
							(branch
								(patterns
									(pattern (degenerate false)
										(p-applied-tag)))
								(value
									(e-spawn
										(e-call
											(e-runtime-error (tag "ident_not_in_scope"))
											(e-lookup-local
												(p-assign (ident "v")))))))
							(branch
								(patterns
									(pattern (degenerate false)
										(p-applied-tag)))
								(value
									(e-empty_record)))))))
			(e-empty_record))))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs)
	(expressions))
~~~
