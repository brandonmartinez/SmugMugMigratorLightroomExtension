-- Run the NameMapping module against a fixture set and exit non-zero on failure.
package.path = "../?.lua;" .. package.path
local NM = require "NameMapping"

local failures = 0
local function check(label, got, want)
    if got ~= want then
        failures = failures + 1
        io.write(string.format("FAIL %s: got %q, want %q\n", label, tostring(got), tostring(want)))
    else
        io.write(string.format("ok   %s\n", label))
    end
end

-- isRootSkip
check("root skip exact",   tostring(NM.isRootSkip("Client Download")),       "true")
check("root skip lower",   tostring(NM.isRootSkip("client download")),       "true")
check("root skip padded",  tostring(NM.isRootSkip("  Client Download  ")),  "true")
check("root skip nope",    tostring(NM.isRootSkip("Client Downloads")),     "false")
check("root skip nil",     tostring(NM.isRootSkip(nil)),                    "false")

-- mapGalleryName valid
local r = NM.mapGalleryName("20240315 - Smith Wedding")
check("valid map name",      r.name,        "2024-03-15 - Smith Wedding")
check("valid map transformed", tostring(r.transformed), "true")
check("valid map warning",   tostring(r.warning),  "nil")

-- Leap day valid
r = NM.mapGalleryName("20240229 - Leap")
check("leap valid name",      r.name,        "2024-02-29 - Leap")
check("leap valid transformed", tostring(r.transformed), "true")

-- Non-leap invalid date
r = NM.mapGalleryName("20230229 - NotLeap")
check("non-leap invalid name",   r.name,        "20230229 - NotLeap")
check("non-leap invalid transformed", tostring(r.transformed), "false")
check("non-leap invalid has warning", tostring(r.warning ~= nil), "true")

-- Invalid month
r = NM.mapGalleryName("20241399 - Foo")
check("bad month name",          r.name,        "20241399 - Foo")
check("bad month transformed",   tostring(r.transformed), "false")

-- Doesn't match regex
r = NM.mapGalleryName("Just an album")
check("no match name",           r.name,        "Just an album")
check("no match transformed",    tostring(r.transformed), "false")

-- Whitespace around dash
r = NM.mapGalleryName("20240101-NoSpace")
check("no-space name",           r.name,        "2024-01-01-NoSpace")

-- 9 digits should not match (would otherwise greedily consume)
r = NM.mapGalleryName("202401015 - Suspect")
check("9 digits no match",       tostring(r.transformed), "false")

-- mapFolderName trims
check("folder trim",             NM.mapFolderName("  Smiths  "), "Smiths")

if failures > 0 then
    io.write(string.format("\n%d failure(s)\n", failures))
    os.exit(1)
end
io.write("\nall passed\n")
