local test = require("lde-test")
local Tokenizer = require("ffix.tokenizer")

local function tok(src)
	return Tokenizer.new():tokenize(src)
end

-- idents and keywords

test.it("tokenizes a plain ident", function()
	test.match(tok("myVar"), { { variant = "ident", ident = "myVar" } })
end)

test.it("tokenizes underscore ident", function()
	test.match(tok("_size_t"), { { variant = "ident", ident = "_size_t" } })
end)

test.it("keywords produce their variant directly", function()
	for _, kw in ipairs({ "typedef", "struct", "enum", "union", "const", "extern",
		"unsigned", "signed", "void", "char", "short", "int", "long", "float", "double",
		"static", "volatile", "restrict" }) do
		test.match(tok(kw), { { variant = kw } })
	end
end)

-- numbers

test.it("tokenizes decimal integer", function()
	test.match(tok("42"), { { variant = "number", number = 42 } })
end)

test.it("tokenizes integer with suffix", function()
	test.match(tok("100u"), { { variant = "number", number = 100 } })
end)

test.it("tokenizes hex number", function()
	test.match(tok("0xff"), { { variant = "number", number = 255 } })
end)

test.it("tokenizes float", function()
	test.match(tok("3.14"), { { variant = "number", number = 3.14 } })
end)

-- strings

test.it("tokenizes a double-quoted string", function()
	test.match(tok('"hello world"'), { { variant = "string", string = "hello world" } })
end)

-- specials

test.it("tokenizes single-char specials", function()
	for _, s in ipairs({ "{", "}", "[", "]", "(", ")", ",", ".", ";", ":", "<", ">", "*", "&", "~" }) do
		test.match(tok(s), { { variant = s } })
	end
end)

test.it("tokenizes :: as one token", function()
	test.match(tok("::"), { { variant = "::" } })
end)

test.it("tokenizes ... as one token", function()
	test.match(tok("..."), { { variant = "..." } })
end)

-- whitespace and comments

test.it("skips whitespace", function()
	test.match(tok("  int  "), { { variant = "int" } })
end)

test.it("skips // comments", function()
	test.match(tok("// comment\nint"), { { variant = "int" } })
end)

test.it("skips # comments", function()
	test.match(tok("# preprocessor\nchar"), { { variant = "char" } })
end)

-- multi-token sequences

test.it("tokenizes typedef sequence", function()
	test.match(tok("typedef int MyInt;"), {
		{ variant = "typedef" },
		{ variant = "int" },
		{ variant = "ident", ident = "MyInt" },
		{ variant = ";" },
	})
end)

test.it("tokenizes pointer with qualifiers", function()
	test.match(tok("const char * restrict"), {
		{ variant = "const" },
		{ variant = "char" },
		{ variant = "*" },
		{ variant = "restrict" },
	})
end)

test.it("tokenizes a function signature", function()
	test.match(tok("void foo(int x, char *y);"), {
		{ variant = "void" },
		{ variant = "ident", ident = "foo" },
		{ variant = "(" },
		{ variant = "int" },
		{ variant = "ident", ident = "x" },
		{ variant = "," },
		{ variant = "char" },
		{ variant = "*" },
		{ variant = "ident", ident = "y" },
		{ variant = ")" },
		{ variant = ";" },
	})
end)
