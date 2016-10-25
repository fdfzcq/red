REBOL [
	Title:   "Compilation directives processing"
	Author:  "Nenad Rakocevic"
	File: 	 %preprocessor.r
	Tabs:	 4
	Rights:  "Copyright (C) 2016 Nenad Rakocevic. All rights reserved."
	License: "BSD-3 - https://github.com/red/red/blob/master/BSD-3-License.txt"
]
Red []													;-- make it usable by Red too.

preprocessor: context [
	exec:	none										;-- object that captures directive words
	protos: make block! 10
	macros: make block! 10
	syms:	make block! 20
	active?: yes
	
	do-quit: does [
		either all [rebol system/options/args][quit/return 1][halt]
	]
	
	throw-error: func [error [error!] cmd [issue!] code [block!] /local w][
		prin ["*** Preprocessor Error in" mold cmd lf]
		error/where: new-line/all reduce [cmd] no
		
		#either none? config [							;-- config is none when preprocessor is applied to itself
			error: disarm error
			foreach w [arg1 arg2 arg3][
				set w either unset? get/any in error w [none][
					get/any in error w
				]
			]
			print [
				"***" system/error/(error/type)/type #":"
				reduce system/error/(error/type)/(error/id) newline
				"*** Where:" mold/flat error/where newline
				"*** Near: " mold/flat error/near newline
			]
			do-quit
		][
			print form :error
			halt
		]
	]
	
	do-code: func [code [block!] cmd [issue!] /local p res w][
		clear syms
		parse code [any [
			p: set-word! (unless in exec p/1 [append syms p/1])
			| skip
		]]
		unless empty? syms [exec: make exec append syms none]
		
		if error? set 'res try bind code exec [throw-error res cmd code]
		:res
	]
	
	count-args: func [spec [block!] /local total][
		total: 0
		parse spec [
			any [
				[word! | lit-word! | get-word!] (total: total + 1)
				| refinement! (return total)
			]
		]
		total
	]
	
	func-arity?: func [spec [block!] /with path [path!] /local arity pos][
		arity: count-args spec
		if path [
			foreach word next path	[
				unless pos: find/tail spec to refinement! word [
					print [
						"*** Macro Error: unknown refinement in"
						mold path
					]
					do-quit
				]
				arity: arity + count-args pos
			]
		]
		arity
	]
	
	fetch-next: func [code [block!] /local base arity value path][
		base: code
		arity: 1
		
		while [arity > 0][
			arity: arity + either all [
				not tail? next code
				word? value: code/2
				op? get/any value
			][
				code: next code
				1
			][
				either all [
					find [word! path!] type?/word value: code/1
					value: either word? value [value][first path: value]
					any-function? get/any value
				][
					either path [
						func-arity?/with spec-of get value path
					][
						func-arity? spec-of get value
					]
				][0]
			]
			code: next code
			arity: arity - 1
		]
		code
	]
	
	eval: func [code [block!] cmd [issue!] /local after expr][
		after: fetch-next code
		expr: copy/part code after
		expr: do-code expr cmd
		reduce [expr after]
	]
	
	do-macro: func [name pos [block! paren!] arity [integer!] /local cmd][
		cmd: clear []
		append cmd name
		append cmd copy/part next pos arity
		do bind cmd exec
	]
	
	register-macro: func [spec [block!] /local cnt rule p name][
		cnt: 0
		rule: make block! 10
		unless parse spec/3 [
			any [
				opt string! 
				word! (cnt: cnt + 1)
				opt [
					p: block! :p into [some word!]
						;(append/only rule make block! 1)
						;some [p: word! (append last rule p/1)]
						;(append rule '|)
					;]
				]
				opt [/local some word!]
			]
		][
			print [
				"*** Macro Error: invalid specification:"
				mold copy/part spec 3
			]
			do-quit
		]
		repend rule [
			name: to lit-word! spec/1
			to-paren compose [change/part s do-macro (:name) s (cnt) (cnt + 1)]
			first [:s]
		]
		either tag? macros/1 [remove macros][append macros '|]
		append macros rule
		
		append protos copy/part spec 4
		exec: make exec protos
	]
	
	expand: func [
		code [block!] job [object! none!]
		/local rule s e pos cond value then else cases body skip?
	][
		exec: context [config: job]
		clear protos
		insert clear macros <none>						;-- required to avoid empty rule (causes infinite loop)
		
		#process off
		parse code rule: [
			any [
				s: macros
				| 'routine 2 skip						;-- avoid overlapping with R/S preprocessor
				| #system skip
				| #system-global skip
				
				| s: #include (
					if all [active? not Rebol system/state/interpreted?][s/1: 'do]
				)
				| s: #if (set [cond e] eval next s s/1) :e set then block! e: (
					if active? [either cond [change/part s then e][remove/part s e]]
				) :s
				| s: #either (set [cond e] eval next s s/1) :e set then block! set else block! e: (
					if active? [either cond [change/part s then e][change/part s else e]]
				) :s
				| s: #switch (set [cond e] eval next s s/1) :e set cases block! e: (
					if active? [
						body: any [select cases cond select cases #default]
						either body [change/part s body e][remove/part s e]
					]
				) :s
				| s: #case set cases block! e: (
					if active? [
						until [
							set [cond cases] eval cases s/1
							any [cond tail? cases: next cases]
						]
						either cond [change/part s cases/1 e][remove/part s e]
					]
				) :s
				| s: #do (skip?: no) opt ['skip (skip?: yes)] block! e: (
					if active? [
						either skip? [remove/part s e][s: change/part s do-code s/2 s/1 e]
					]
				) :s
				
				| s: #process [
					  'on  (active?: yes remove/part s 2) :s
					| 'off (active?: no  remove/part s 2) :s [to #process | to end]
				]
				  
				| s: #macro set-word! ['func | 'function] block! block! e: (
					register-macro next s
					bind macros 'code					;-- bind newly formed macros to 'expand
					remove/part s e
				) :s
				| pos: [block! | paren!] :pos into rule
				| skip
			]
		]
		#process on
		code
	]
	
	set 'expand-directives func [						;-- to be called from Red only
		code [block!]
	][
		expand code system/build/config
	]
]