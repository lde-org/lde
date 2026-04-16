local test = require("lde-test")
local Tokenizer = require("ffix.tokenizer")
local Parser = require("ffix.parser")
local Printer = require("ffix.printer")

local function roundtrip(src)
	local tokens = Tokenizer.new():tokenize(src)
	local ok, nodes = Parser.new():parse(tokens)
	test.truthy(ok)
	return Printer.new():print(nodes)
end

test.it("typedef alias", function()
	test.equal(roundtrip("typedef int MyInt;"), "typedef int MyInt;")
end)

test.it("typedef pointer alias", function()
	test.equal(roundtrip("typedef char * string_t;"), "typedef char *string_t;")
end)

test.it("typedef qualified alias", function()
	test.equal(roundtrip("typedef const unsigned int uint_t;"), "typedef const unsigned int uint_t;")
end)

test.it("typedef double-pointer alias", function()
	test.equal(roundtrip("typedef void ** handle_t;"), "typedef void **handle_t;")
end)

test.it("typedef struct anonymous", function()
	test.equal(roundtrip("typedef struct { int x; int y; } Point;"), [[
typedef struct {
	int x;
	int y;
} Point;]])
end)

test.it("typedef struct with tag", function()
	test.equal(roundtrip("typedef struct Node { int val; } Node;"), [[
typedef struct Node {
	int val;
} Node;]])
end)

test.it("typedef struct pointer field", function()
	test.equal(roundtrip("typedef struct { struct Node * next; } Node;"), [[
typedef struct {
	struct Node *next;
} Node;]])
end)

test.it("typedef enum", function()
	test.equal(roundtrip("typedef enum { RED, GREEN, BLUE, } Color;"), [[
typedef enum {
	RED,
	GREEN,
	BLUE,
} Color;]])
end)

test.it("typedef enum with tag", function()
	test.equal(roundtrip("typedef enum Dir { UP, DOWN, } Dir;"), [[
typedef enum Dir {
	UP,
	DOWN,
} Dir;]])
end)

test.it("typedef function pointer no params", function()
	test.equal(roundtrip("typedef void (*Callback)(void);"), "typedef void (*Callback)(void);")
end)

test.it("typedef function pointer with params", function()
	test.equal(
		roundtrip("typedef int (*Comparator)(const void * a, const void * b);"),
		"typedef int (*Comparator)(const void *a, const void *b);"
	)
end)

test.it("typedef function pointer returning pointer", function()
	test.equal(roundtrip("typedef char * (*Getter)(int key);"), "typedef char *(*Getter)(int key);")
end)

test.it("function declaration no params", function()
	test.equal(roundtrip("void init(void);"), "void init(void);")
end)

test.it("function declaration named params", function()
	test.equal(roundtrip("int add(int a, int b);"), "int add(int a, int b);")
end)

test.it("function declaration unnamed params", function()
	test.equal(roundtrip("int add(int, int);"), "int add(int, int);")
end)

test.it("function returning pointer", function()
	test.equal(roundtrip("char * strdup(const char * s);"), "char *strdup(const char *s);")
end)

test.it("function with void pointer param", function()
	test.equal(roundtrip("void free(void * ptr);"), "void free(void *ptr);")
end)

test.it("extern variable", function()
	test.equal(roundtrip("extern int errno;"), "extern int errno;")
end)

test.it("extern pointer", function()
	test.equal(roundtrip("extern char * environ;"), "extern char *environ;")
end)

test.it("fn_decl with __asm__ roundtrips", function()
	test.equal(
		roundtrip("int mylib_add(int a, int b) __asm__(\"add\");"),
		"int mylib_add(int a, int b) __asm__(\"add\");"
	)
end)

test.it("extern_var with __asm__ roundtrips", function()
	test.equal(
		roundtrip("extern int mylib_errno __asm__(\"errno\");"),
		"extern int mylib_errno __asm__(\"errno\");"
	)
end)

test.it("multiple nodes", function()
	test.equal(roundtrip("typedef int size_t;\nextern int errno;"), "typedef int size_t;\nextern int errno;")
end)
