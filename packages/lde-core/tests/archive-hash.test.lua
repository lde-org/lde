const test = require("lde-test")
const fs = require("fs")
const path = require("path")
const process = require("process")
const curl = require("curl-sys")

const archive = require("lde-core.global.archive")
const sha256 = require("lde-core.util.sha256")

local hasPython = (process.exec("python3", { "--version" }) or 1) == 0

local function sha256File(file)
	return sha256.sumhexa(fs.read(file))
end

test.skipIf(jit.os == "Windows" or not hasPython)("verifies a published archive hash before extraction", function()
	local dir = "/tmp/lde-archive-hash-" .. tostring(os.time()) .. "-" .. tostring({}):match("0x(%x+)$")
	fs.mkdirAll(dir)
	fs.write(path.join(dir, "hello.txt"), "hello")
	local tarball = dir .. ".tar.gz"
	local code = process.exec("tar", { "-czf", tarball, "-C", dir, "hello.txt" })
	test.equal(code, 0)
	local hash = sha256File(tarball)
	test.equal(#hash, 64)

	local port = 18099
	local server = process.spawn("python3", {
		"-m", "http.server", tostring(port), "--bind", "127.0.0.1", "--directory", dir,
	})
	test.truthy(server)
	for _ = 1, 30 do
		local res = curl.get("http://127.0.0.1:" .. port .. "/hello.txt")
		if res then break end
		process.exec("sleep", { "0.1" })
	end

	local url = "http://127.0.0.1:" .. port .. "/hello.txt.tar.gz"
	-- The tarball is named hello.txt.tar.gz next to hello.txt.
	fs.copy(tarball, path.join(dir, "hello.txt.tar.gz"))

	local badOk, badErr = pcall(archive.getOrInitArchive, url, false, nil, string.rep("0", 64))
	test.falsy(badOk)
	test.includes(tostring(badErr), "SHA-256 check")

	local ok, archiveDir = pcall(archive.getOrInitArchive, url, false, nil, hash)
	if not ok then print("archive error", tostring(archiveDir)) end
	test.truthy(ok)
	test.truthy(fs.exists(archiveDir))

	fs.rmdir(archiveDir)
	fs.delete(tarball)
	fs.delete(path.join(dir, "hello.txt.tar.gz"))
	fs.rmdir(dir)
	server:kill(true)
end)
