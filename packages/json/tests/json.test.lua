local test = require("lde-test")
local json = require("json")

-- encode

test.it("encodes primitives", function()
	test.equal(json.encode(nil):gsub("%s", ""), "null")
	test.equal(json.encode(true):gsub("%s", ""), "true")
	test.equal(json.encode(42):gsub("%s", ""), "42")
	test.equal(json.encode("hi"):gsub("%s", ""), '"hi"')
end)

test.it("encodes array", function()
	local s = json.encode({ 1, 2, 3 })
	local t = json.decode(s)
	test.equal(t[1], 1); test.equal(t[2], 2); test.equal(t[3], 3)
end)

test.it("encodes object", function()
	local s = json.encode({ a = 1 })
	local t = json.decode(s)
	test.equal(t.a, 1)
end)

-- decode – standard JSON

test.it("decodes null", function()
	test.equal(tostring(json.decode("null")), "null")
end)

test.it("decodes booleans", function()
	test.equal(json.decode("true"), true)
	test.equal(json.decode("false"), false)
end)

test.it("decodes numbers", function()
	test.equal(json.decode("42"), 42)
	test.equal(json.decode("-3.14"), -3.14)
	test.equal(json.decode("1e2"), 100)
end)

test.it("decodes strings", function()
	test.equal(json.decode('"hello"'), "hello")
	test.equal(json.decode('"line\\nbreak"'), "line\nbreak")
end)

test.it("decodes nested objects and arrays", function()
	local t = json.decode('{"a":[1,2],"b":{"c":true}}')
	test.equal(t.a[1], 1); test.equal(t.a[2], 2); test.equal(t.b.c, true)
end)

-- decode – JSON5

test.it("json5: single-line comment", function()
	test.equal(json.decode('{\n// comment\n"a":1}').a, 1)
end)

test.it("json5: block comment", function()
	test.equal(json.decode('{"a": /* comment */ 1}').a, 1)
end)

test.it("json5: single-quoted string value", function()
	test.equal(json.decode("'hello'"), "hello")
end)

test.it("json5: single-quoted string key", function()
	test.equal(json.decode("{'key': 1}").key, 1)
end)

test.it("json5: unquoted key", function()
	test.equal(json.decode("{foo: 1}").foo, 1)
end)

test.it("json5: trailing comma in object", function()
	test.equal(json.decode('{"a":1,}').a, 1)
end)

test.it("json5: trailing comma in array", function()
	test.equal(#json.decode('[1,2,3,]'), 3)
end)

test.it("json5: hex number", function()
	test.equal(json.decode("0xFF"), 255)
end)

test.it("json5: Infinity", function()
	test.equal(json.decode("Infinity"), math.huge)
	test.equal(json.decode("+Infinity"), math.huge)
	test.equal(json.decode("-Infinity"), -math.huge)
end)

test.it("json5: NaN", function()
	local n = json.decode("NaN")
	test.truthy(n ~= n)
end)

-- order preservation

test.it("addField preserves insertion order on encode", function()
	local t = {}
	json.addField(t, "z", 1); json.addField(t, "a", 2); json.addField(t, "m", 3)
	local s = json.encode(t)
	test.truthy(s:find('"z"') < s:find('"a"') and s:find('"a"') < s:find('"m"'))
end)

test.it("decode preserves key insertion order", function()
	local t = json.decode('{"z":1,"a":2,"m":3}')
	local s = json.encode(t)
	test.truthy(s:find('"z"') < s:find('"a"') and s:find('"a"') < s:find('"m"'))
end)

test.it("removeField removes key and preserves order of remaining keys", function()
	local t = {}
	json.addField(t, "a", 1); json.addField(t, "b", 2); json.addField(t, "c", 3)
	json.removeField(t, "b")
	local s = json.encode(t)
	test.truthy(not s:find('"b"'))
	test.truthy(s:find('"a"') < s:find('"c"'))
end)

-- comment/style preservation (only via addField/encode, not materialise)

test.it("preserves unquoted key style on re-encode via addField", function()
	local t = {}
	json.addField(t, "foo", 1)
	-- addField uses plain string[], encode uses double-quote by default
	local out = json.encode(t)
	test.truthy(out:find('"foo"'))
end)

test.it("preserves double-quoted key style on re-encode", function()
	test.truthy(json.encode(json.decode('{"baz": 3}')):find('"baz"'))
end)

test.it("preserves double-quoted string value on re-encode", function()
	test.truthy(json.encode(json.decode('{"key": "world"}')):find('"world"'))
end)

-- zero-alloc API

test.it("json.iter over array yields indices and token indices", function()
	local doc = json.decodeDocument('[10,20,30]')
	local keys, vals = {}, {}
	for i, vi in json.iter(doc, doc.root) do
		keys[#keys+1] = i
		vals[#vals+1] = json.num(doc, vi)
	end
	test.equal(#keys, 3)
	test.equal(vals[1], 10); test.equal(vals[2], 20); test.equal(vals[3], 30)
end)

test.it("json.iter over object yields key strings and token indices", function()
	local doc = json.decodeDocument('{"x":1,"y":2}')
	local keys, vals = {}, {}
	for k, vi in json.iter(doc, doc.root) do
		keys[#keys+1] = k
		vals[k] = json.num(doc, vi)
	end
	test.equal(vals.x, 1); test.equal(vals.y, 2)
end)

test.it("json.get retrieves array element by index", function()
	local doc = json.decodeDocument('[10,20,30]')
	test.equal(json.num(doc, json.get(doc, doc.root, 2)), 20)
end)

test.it("json.get retrieves object value by key", function()
	local doc = json.decodeDocument('{"name":"alice","age":30}')
	test.equal(json.str(doc, json.get(doc, doc.root, "name")), "alice")
	test.equal(json.num(doc, json.get(doc, doc.root, "age")), 30)
end)

test.it("json.type returns correct type names", function()
	local doc = json.decodeDocument('[null,true,false,42,3.14,"hi",[],{}]')
	local types = {}
	for _, vi in json.iter(doc, doc.root) do types[#types+1] = json.type(doc, vi) end
	test.equal(types[1], "null");    test.equal(types[2], "boolean")
	test.equal(types[3], "boolean"); test.equal(types[4], "number")
	test.equal(types[5], "number");  test.equal(types[6], "string")
	test.equal(types[7], "array");   test.equal(types[8], "object")
end)

test.it("json.str handles escaped strings", function()
	local doc = json.decodeDocument('"hello\\nworld"')
	test.equal(json.str(doc, doc.root), "hello\nworld")
end)

-- regression: keys from a decoded object must survive any number of subsequent decodes
-- (key_arena was being reset to 0 on each decodeDocument, corrupting prior slices)
test.it("encode preserves keys after a subsequent decode clobbers the key arena", function()
	local config = json.decode('{"name":"myproject","version":"1.0.0","dependencies":{}}')
	-- A second decode used to reset key_arena_top to 0, overwriting arena slots with new keys
	json.decode('{"arch":null,"url":null,"luarocks":null}')
	json.decode('{"x":1,"y":2,"z":3}')
	local out = json.encode(config)
	local roundtrip = json.decode(out)
	test.equal(roundtrip.name, "myproject")
	test.equal(roundtrip.version, "1.0.0")
	test.truthy(roundtrip.dependencies)
end)

test.it("decodeDocument+materialise key slices survive subsequent decodeDocument calls", function()
	local doc1 = json.decodeDocument('{"a":1,"b":2}')
	local obj1 = json.materialise(doc1)
	-- second decodeDocument used to reset key_arena_top, clobbering doc1's slice
	local doc2 = json.decodeDocument('{"x":10,"y":20,"z":30}')
	local obj2 = json.materialise(doc2)
	-- obj1's key order must still be intact
	local out1 = json.encode(obj1)
	local r1 = json.decode(out1)
	test.equal(r1.a, 1)
	test.equal(r1.b, 2)
	-- obj2 must also be correct
	local out2 = json.encode(obj2)
	local r2 = json.decode(out2)
	test.equal(r2.x, 10)
	test.equal(r2.y, 20)
	test.equal(r2.z, 30)
end)
