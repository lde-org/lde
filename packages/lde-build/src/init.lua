local outDir = os.getenv("LDE_OUTPUT_DIR") or os.getenv("LPM_OUTPUT_DIR")
assert(outDir, "lde-build: LDE_OUTPUT_DIR is not set")

return require("lde-build.build").new(outDir)
