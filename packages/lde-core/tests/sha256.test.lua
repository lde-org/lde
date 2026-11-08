const test = require("lde-test")
const sha256 = require("lde-core.util.sha256")

test.it("hashes the empty string", function()
	test.equal(sha256.sumhexa(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
end)

test.it("hashes abc and the FIPS multi-block vector", function()
	test.equal(sha256.sumhexa("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	test.equal(
		sha256.sumhexa("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
		"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
	)
end)

test.it("hashes a message spanning many blocks", function()
	test.equal(
		sha256.sumhexa(string.rep("a", 1000000)),
		"cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
	)
end)
