-- Pure-Lua tests for Planner.lua.
package.path = "../?.lua;" .. package.path
local Planner = require "Planner"

local failures = 0
local function check(label, got, want)
    if got ~= want then
        failures = failures + 1
        io.write(string.format("FAIL %s: got %q, want %q\n", label, tostring(got), tostring(want)))
    else
        io.write(string.format("ok   %s\n", label))
    end
end

-- Helper to build test fixture trees.
local function set(name, children) return { kind = "set", name = name, children = children or {}, sdk = name } end
local function gal(name) return { kind = "gallery", name = name, sdk = name } end

-- ── happy path: standard SmugMug layout ───────────────────────────────────
local walked = {
    rootChildren = {
        set("Client Download", {
            set("Smith", {
                gal("20240315 - Wedding"),
                gal("20240601 - Reception"),
            }),
            set("Jones", {
                gal("20240505 - Engagement"),
            }),
        }),
    },
}

local plan, warnings = Planner.plan(walked)

check("happy: ancestor count",      #plan.ancestorSets, 3) -- _archive, Smith, Jones
check("happy: album count",         #plan.albums,        3)
check("happy: zero warnings",       #warnings,           0)
check("happy: first album target",  plan.albums[1].target.name, "2024-03-15 - Wedding")
check("happy: first album parent",  table.concat(plan.albums[1].target.parentPath, "/"), "_archive/Smith")
check("happy: third album target",  plan.albums[3].target.name, "2024-05-05 - Engagement")
check("happy: ancestor includes Smith", (function()
    for _, a in ipairs(plan.ancestorSets) do
        if a.name == "Smith" and table.concat(a.path, "/") == "_archive/Smith" then return true end
    end
    return false
end)() and "true" or "false", "true")

-- ── non-standard root folder name → warning, still mapped ─────────────────
local walked2 = {
    rootChildren = {
        set("Other Root Folder", {
            set("ClientA", { gal("20240101 - Album") }),
        }),
    },
}
local p2, w2 = Planner.plan(walked2)
check("non-std: album count", #p2.albums, 1)
check("non-std: target parent", table.concat(p2.albums[1].target.parentPath, "/"), "_archive/Other Root Folder/ClientA")
check("non-std: warning emitted", #w2 >= 1 and "true" or "false", "true")
check("non-std: warning kind", w2[1].kind, "non-standard-root")

-- ── gallery directly under publish service root → warning + landed ────────
local walked3 = {
    rootChildren = {
        gal("20240101 - LoneAlbum"),
    },
}
local p3, w3 = Planner.plan(walked3)
check("lone gallery: count", #p3.albums, 1)
check("lone gallery: parent", table.concat(p3.albums[1].target.parentPath, "/"), "_archive")
check("lone gallery: target name", p3.albums[1].target.name, "2024-01-01 - LoneAlbum")
check("lone gallery: warning kind", w3[1].kind, "root-gallery")

-- ── invalid gallery date → warning, name unchanged ────────────────────────
local walked4 = {
    rootChildren = {
        set("Client Download", {
            set("Smith", { gal("20230229 - BadDate") }),
        }),
    },
}
local p4, w4 = Planner.plan(walked4)
check("invalid date: kept verbatim", p4.albums[1].target.name, "20230229 - BadDate")
check("invalid date: warning emitted", #w4, 1)
check("invalid date: warning kind", w4[1].kind, "gallery-name")

-- ── empty subfolder name → skipped subtree with warning ───────────────────
local walked5 = {
    rootChildren = {
        set("Client Download", {
            set("   ", { gal("20240101 - X") }),
            set("Real", { gal("20240202 - Y") }),
        }),
    },
}
local p5, w5 = Planner.plan(walked5)
check("empty folder: album count", #p5.albums, 1) -- only Real/Y
check("empty folder: target parent", table.concat(p5.albums[1].target.parentPath, "/"), "_archive/Real")
check("empty folder: warning kind", w5[1].kind, "empty-folder-name")

-- ── ancestor de-duplication: same set name visited twice produces one entry ─
local walked6 = {
    rootChildren = {
        set("Client Download", {
            set("Smith", { gal("20240101 - A") }),
            set("Smith", { gal("20240202 - B") }), -- duplicate name (unusual, but defend against)
        }),
    },
}
local p6, w6 = Planner.plan(walked6)
-- ancestorSets should de-dupe by path: _archive + _archive/Smith = 2 entries
local smithCount = 0
for _, a in ipairs(p6.ancestorSets) do
    if a.name == "Smith" then smithCount = smithCount + 1 end
end
check("dedup ancestor: Smith count", smithCount, 1)
check("dedup ancestor: total album count", #p6.albums, 2)

-- ── _archive itself listed as ancestor ─────────────────────────────────────
local found = false
for _, a in ipairs(plan.ancestorSets) do
    if a.name == "_archive" then found = true end
end
check("archive root present in ancestors", tostring(found), "true")

if failures > 0 then
    io.write(string.format("\n%d failure(s)\n", failures))
    os.exit(1)
end
io.write("\nall passed\n")
