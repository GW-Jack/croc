# META
~~~ini
description=ParallelTasks is recorded on the platform header
type=file
~~~
# SOURCE
~~~roc
platform "test-platform"
	requires {}
	exposes []
	packages {}
	provides {}
	concurrency: ParallelTasks

helper = 1
~~~
# EXPECTED
NIL
# PROBLEMS
NIL
# TOKENS
~~~zig
KwPlatform,StringStart,StringPart,StringEnd,
KwRequires,OpenCurly,CloseCurly,
KwExposes,OpenSquare,CloseSquare,
KwPackages,OpenCurly,CloseCurly,
KwProvides,OpenCurly,CloseCurly,
LowerIdent,OpColon,UpperIdent,
LowerIdent,OpAssign,Int,
EndOfFile,
~~~
# PARSE
~~~clojure
(file
	(platform (name "test-platform") (concurrency "ParallelTasks")
		(requires)
		(exposes)
		(packages)
		(provides))
	(statements
		(s-decl
			(p-ident (raw "helper"))
			(e-int (raw "1")))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(can-ir
	(d-let
		(p-assign (ident "helper"))
		(e-num (value "1"))))
~~~
# TYPES
~~~clojure
(inferred-types
	(defs
		(patt (type "Dec")))
	(expressions
		(expr (type "Dec"))))
~~~
