local test = require("lde-test")
local Tokenizer = require("ffix.tokenizer")
local Parser = require("ffix.parser")

local function parse(src)
	local tokens = Tokenizer.new():tokenize(src)
	local ok, nodes = Parser.new():parse(tokens)
	test.truthy(ok)
	return nodes
end

-- typedef alias

test.it("typedef primitive alias", function()
	test.match(parse("typedef int MyInt;"), {
		{ kind = "typedef_alias", name = "MyInt", type = { name = "int", pointer = 0, qualifiers = {} } },
	})
end)

test.it("typedef pointer alias", function()
	test.match(parse("typedef char * string_t;"), {
		{ kind = "typedef_alias", name = "string_t", type = { name = "char", pointer = 1 } },
	})
end)

test.it("typedef with qualifier", function()
	test.match(parse("typedef const unsigned int uint_t;"), {
		{ kind = "typedef_alias", name = "uint_t", type = { name = "int", qualifiers = { "const", "unsigned" } } },
	})
end)

test.it("typedef double-pointer", function()
	test.match(parse("typedef void ** handle_t;"), {
		{ kind = "typedef_alias", name = "handle_t", type = { name = "void", pointer = 2 } },
	})
end)

-- typedef struct

test.it("typedef anonymous struct", function()
	test.match(parse("typedef struct { int x; int y; } Point;"), {
		{
			kind = "typedef_struct",
			name = "Point",
			tag = nil,
			fields = {
				{ name = "x", type = { name = "int" } },
				{ name = "y", type = { name = "int" } },
			},
		},
	})
end)

test.it("typedef struct with tag", function()
	test.match(parse("typedef struct Node { int val; } Node;"), {
		{ kind = "typedef_struct", name = "Node", tag = "Node" },
	})
end)

test.it("typedef struct with pointer field", function()
	test.match(parse("typedef struct { struct Node * next; } Node;"), {
		{
			kind = "typedef_struct",
			fields = { { name = "next", type = { name = "struct Node", pointer = 1 } } },
		},
	})
end)

test.it("typedef struct with array field", function()
	test.match(parse("typedef struct { char buf[256]; } Buf;"), {
		{ kind = "typedef_struct", fields = { { name = "buf", type = { name = "char" } } } },
	})
end)

test.it("typedef struct with multiple fields of different types", function()
	test.match(parse("typedef struct { unsigned int id; const char * name; } Record;"), {
		{
			kind = "typedef_struct",
			name = "Record",
			fields = {
				{ name = "id",   type = { name = "int", qualifiers = { "unsigned" } } },
				{ name = "name", type = { name = "char", pointer = 1 } },
			},
		},
	})
end)

-- typedef enum

test.it("typedef enum", function()
	test.match(parse("typedef enum { RED, GREEN, BLUE, } Color;"), {
		{
			kind = "typedef_enum",
			name = "Color",
			variants = { { name = "RED" }, { name = "GREEN" }, { name = "BLUE" } },
		},
	})
end)

test.it("typedef enum with tag", function()
	test.match(parse("typedef enum Dir { UP, DOWN, } Dir;"), {
		{ kind = "typedef_enum", name = "Dir", tag = "Dir" },
	})
end)

-- typedef function pointer

test.it("typedef function pointer no params", function()
	test.match(parse("typedef void (*Callback)(void);"), {
		{ kind = "typedef_fnptr", name = "Callback", ret = { name = "void" }, params = {} },
	})
end)

test.it("typedef function pointer with params", function()
	test.match(parse("typedef int (*Comparator)(const void * a, const void * b);"), {
		{
			kind = "typedef_fnptr",
			name = "Comparator",
			ret = { name = "int" },
			params = {
				{ type = { name = "void", pointer = 1 } },
				{ type = { name = "void", pointer = 1 } },
			},
		},
	})
end)

test.it("typedef function pointer returning pointer", function()
	test.match(parse("typedef char * (*Getter)(int key);"), {
		{
			kind = "typedef_fnptr",
			name = "Getter",
			ret = { name = "char", pointer = 1 },
			params = { { type = { name = "int" } } },
		},
	})
end)

-- function declarations

test.it("void function no params", function()
	test.match(parse("void init(void);"), {
		{ kind = "fn_decl", name = "init", ret = { name = "void" }, params = {} },
	})
end)

test.it("function with named params", function()
	test.match(parse("int add(int a, int b);"), {
		{
			kind = "fn_decl",
			name = "add",
			ret = { name = "int" },
			params = {
				{ name = "a", type = { name = "int" } },
				{ name = "b", type = { name = "int" } },
			},
		},
	})
end)

test.it("function with unnamed params", function()
	test.match(parse("int add(int, int);"), {
		{
			kind = "fn_decl",
			name = "add",
			params = {
				{ name = nil, type = { name = "int" } },
				{ name = nil, type = { name = "int" } },
			},
		},
	})
end)

test.it("function returning pointer", function()
	test.match(parse("char * strdup(const char * s);"), {
		{
			kind = "fn_decl",
			name = "strdup",
			ret = { name = "char", pointer = 1 },
			params = { { type = { name = "char", pointer = 1 } } },
		},
	})
end)

test.it("variadic function", function()
	test.match(parse("int printf(const char * fmt, ...);"), {
		{
			kind = "fn_decl",
			name = "printf",
			params = { { type = { name = "char", pointer = 1 } } },
		},
	})
end)

-- extern variable

test.it("extern int", function()
	test.match(parse("extern int errno;"), {
		{ kind = "extern_var", name = "errno", type = { name = "int" } },
	})
end)

test.it("extern pointer", function()
	test.match(parse("extern char * environ;"), {
		{ kind = "extern_var", name = "environ", type = { name = "char", pointer = 1 } },
	})
end)

-- multiple declarations

test.it("parses multiple declarations in sequence", function()
	local nodes = parse([[
		typedef int size_t;
		extern int errno;
		void free(void * ptr);
	]])
	test.equal(#nodes, 3)
	test.equal(nodes[1].kind, "typedef_alias")
	test.equal(nodes[2].kind, "extern_var")
	test.equal(nodes[3].kind, "fn_decl")
end)

-- __asm__ attribute

test.it("fn_decl with __asm__", function()
	test.match(parse("int mylib_add(int a, int b) __asm__(\"add\");"), {
		{ kind = "fn_decl", name = "mylib_add", asm_name = "add" },
	})
end)

test.it("fn_decl with asm (no underscores)", function()
	test.match(parse("void mylib_free(void * ptr) asm(\"free\");"), {
		{ kind = "fn_decl", name = "mylib_free", asm_name = "free" },
	})
end)

test.it("extern_var with __asm__", function()
	test.match(parse("extern int mylib_errno __asm__(\"errno\");"), {
		{ kind = "extern_var", name = "mylib_errno", asm_name = "errno" },
	})
end)

test.it("fn_decl without __asm__ has nil asm_name", function()
	test.match(parse("int add(int a, int b);"), {
		{ kind = "fn_decl", name = "add", asm_name = nil },
	})
end)

-- error handling

test.it("returns false on invalid input", function()
	local tokens = Tokenizer.new():tokenize("int;")
	local ok, nodes = Parser.new():parse(tokens)
	test.falsy(ok)
end)
