local test = require("lde-test")
local ffix = require("ffix")
local Tokenizer = require("ffix.tokenizer")
local Parser = require("ffix.parser")
local Printer = require("ffix.printer")

-- parse + rewrite + print without calling ffi.cdef
local function rewrite(pfx, src)
	local tokens = Tokenizer.new():tokenize(src)
	local ok, nodes = Parser.new():parse(tokens)
	test.truthy(ok)

	local ctx = ffix.context(pfx)
	for _, node in ipairs(nodes) do
		if node.name then ctx.names[node.name] = pfx .. "_" .. node.name end
	end

	local out = {}
	for _, node in ipairs(nodes) do
		out[#out + 1] = ctx:rewriteNode(node)
	end
	return Printer.new():print(out)
end

test.it("typedef alias is prefixed", function()
	test.equal(rewrite("mylib", "typedef int MyInt;"), "typedef int mylib_MyInt;")
end)

test.it("typedef alias referencing another type is rewritten", function()
	test.equal(
		rewrite("mylib", "typedef int MyInt;\ntypedef MyInt MyOtherInt;"),
		"typedef int mylib_MyInt;\ntypedef mylib_MyInt mylib_MyOtherInt;"
	)
end)

test.it("typedef struct fields with user types are rewritten", function()
	test.equal(
		rewrite("mylib", "typedef struct { int x; } Point;\ntypedef struct { Point * origin; } Rect;"),
		"typedef struct {\n\tint x;\n} mylib_Point;\ntypedef struct {\n\tmylib_Point *origin;\n} mylib_Rect;"
	)
end)

test.it("typedef struct with tag rewrites tag too", function()
	test.equal(
		rewrite("mylib", "typedef struct Node { int val; } Node;"),
		"typedef struct mylib_Node {\n\tint val;\n} mylib_Node;"
	)
end)

test.it("typedef enum is prefixed", function()
	test.equal(
		rewrite("mylib", "typedef enum { A, B, } Color;"),
		"typedef enum {\n\tA,\n\tB,\n} mylib_Color;"
	)
end)

test.it("typedef fnptr with user type param is rewritten", function()
	test.equal(
		rewrite("mylib", "typedef struct { int x; } Point;\ntypedef int (*Callback)(Point * p);"),
		"typedef struct {\n\tint x;\n} mylib_Point;\ntypedef int (*mylib_Callback)(mylib_Point *p);"
	)
end)

test.it("fn_decl gets prefixed name and asm attribute", function()
	test.equal(rewrite("mylib", "int add(int a, int b);"), "int mylib_add(int a, int b) __asm__(\"add\");")
end)

test.it("fn_decl with user type params rewrites param types", function()
	test.equal(
		rewrite("mylib", "typedef struct { int x; } Point;\nvoid transform(Point * p);"),
		"typedef struct {\n\tint x;\n} mylib_Point;\nvoid mylib_transform(mylib_Point *p) __asm__(\"transform\");"
	)
end)

test.it("fn_decl preserves existing __asm__ as the asm target", function()
	test.equal(
		rewrite("mylib", "int mylib_add(int a, int b) __asm__(\"add\");"),
		"int mylib_mylib_add(int a, int b) __asm__(\"mylib_add\");"
	)
end)

test.it("extern_var gets prefixed name and asm attribute", function()
	test.equal(rewrite("mylib", "extern int errno_val;"), "extern int mylib_errno_val __asm__(\"errno_val\");")
end)

test.it("extern_var with pointer type is rewritten", function()
	test.equal(
		rewrite("mylib", "extern char * global_buf;"),
		"extern char *mylib_global_buf __asm__(\"global_buf\");"
	)
end)

test.it("struct field reference to tagged struct is rewritten", function()
	test.equal(
		rewrite("mylib", "typedef struct Node { struct Node * next; } Node;"),
		"typedef struct mylib_Node {\n\tstruct mylib_Node *next;\n} mylib_Node;"
	)
end)
