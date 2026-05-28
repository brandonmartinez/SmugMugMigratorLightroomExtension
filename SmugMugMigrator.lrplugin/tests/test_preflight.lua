-- Preflight tests using a hand-rolled mock catalog.
package.path = "../?.lua;" .. package.path
local Preflight = require "Preflight"

local failures = 0
local function check(label, got, want)
    if got ~= want then
        failures = failures + 1
        io.write(string.format("FAIL %s: got %q, want %q\n", label, tostring(got), tostring(want)))
    else
        io.write(string.format("ok   %s\n", label))
    end
end

local function makeSet(name, childSets, childColls)
    return {
        _name = name,
        getName = function(self) return self._name end,
        getChildCollectionSets = function(self) return self._childSets end,
        getChildCollections    = function(self) return self._childColls end,
        _childSets  = childSets  or {},
        _childColls = childColls or {},
    }
end
local function makeColl(name)
    return {
        _name = name,
        getName = function(self) return self._name end,
    }
end
local function makeCatalog(rootSets, rootColls)
    return {
        getChildCollectionSets = function(self) return self._sets  end,
        getChildCollections    = function(self) return self._colls end,
        _sets  = rootSets  or {},
        _colls = rootColls or {},
    }
end

-- A plan helper to keep the tests compact.
local function planFixture(ancestorPaths, albums)
    local ancestorSets = {}
    for _, p in ipairs(ancestorPaths) do
        table.insert(ancestorSets, { path = p, name = p[#p], sourcePath = {} })
    end
    local albumsOut = {}
    for _, a in ipairs(albums) do
        local fp = {}
        for _, s in ipairs(a.parent) do table.insert(fp, s) end
        table.insert(fp, a.name)
        table.insert(albumsOut, {
            source = { name = a.sourceName or a.name, sourcePath = {}, sdk = a.name },
            target = { name = a.name, parentPath = a.parent, fullPath = fp },
            transformed = true,
            warning = nil,
        })
    end
    return { archiveSetName = "_archive", ancestorSets = ancestorSets, albums = albumsOut }
end

-- ── empty catalog: everything is ok-create ────────────────────────────────
do
    local cat = makeCatalog()
    local plan = planFixture(
        { { "_archive" }, { "_archive", "Smith" } },
        { { parent = { "_archive", "Smith" }, name = "2024-03-15 - Wedding" } }
    )
    local r = Preflight.analyze(cat, plan)
    check("empty: ancestors create count",  r.summary.ancestorsToCreate, 2)
    check("empty: ancestors existing count", r.summary.ancestorsExisting, 0)
    check("empty: albums to create",        r.summary.albumsToCreate, 1)
    check("empty: albums to skip",          r.summary.albumsToSkip, 0)
end

-- ── existing _archive set and existing Smith set, no albums yet ───────────
do
    local smith = makeSet("Smith", {}, {})
    local archive = makeSet("_archive", { smith }, {})
    local cat = makeCatalog({ archive })
    local plan = planFixture(
        { { "_archive" }, { "_archive", "Smith" } },
        { { parent = { "_archive", "Smith" }, name = "2024-03-15 - Wedding" } }
    )
    local r = Preflight.analyze(cat, plan)
    check("existing: ancestors existing", r.summary.ancestorsExisting, 2)
    check("existing: ancestors to create", r.summary.ancestorsToCreate, 0)
    check("existing: album to create",    r.summary.albumsToCreate, 1)
end

-- ── existing target collection → skip-existing ────────────────────────────
do
    local existing = makeColl("2024-03-15 - Wedding")
    local smith = makeSet("Smith", {}, { existing })
    local archive = makeSet("_archive", { smith }, {})
    local cat = makeCatalog({ archive })
    local plan = planFixture(
        { { "_archive" }, { "_archive", "Smith" } },
        { { parent = { "_archive", "Smith" }, name = "2024-03-15 - Wedding" } }
    )
    local r = Preflight.analyze(cat, plan)
    check("skip: albums to skip count", r.summary.albumsToSkip, 1)
    check("skip: first album status", r.albums[1].status, "skip-existing")
end

-- ── existing target as collection set (wrong kind) → collision ────────────
do
    local wrongKind = makeSet("2024-03-15 - Wedding", {}, {})
    local smith = makeSet("Smith", { wrongKind }, {})
    local archive = makeSet("_archive", { smith }, {})
    local cat = makeCatalog({ archive })
    local plan = planFixture(
        { { "_archive" }, { "_archive", "Smith" } },
        { { parent = { "_archive", "Smith" }, name = "2024-03-15 - Wedding" } }
    )
    local r = Preflight.analyze(cat, plan)
    check("wrong-kind: album collisions", r.summary.albumCollisions, 1)
    check("wrong-kind: first album status", r.albums[1].status, "collision-wrong-kind")
end

-- ── case-insensitive existing match → skip-existing ───────────────────────
do
    local existing = makeColl("2024-03-15 - WEDDING")
    local smith = makeSet("smith", {}, { existing }) -- lowercase smith
    local archive = makeSet("_ARCHIVE", { smith }, {}) -- shouty
    local cat = makeCatalog({ archive })
    local plan = planFixture(
        { { "_archive" }, { "_archive", "Smith" } },
        { { parent = { "_archive", "Smith" }, name = "2024-03-15 - Wedding" } }
    )
    local r = Preflight.analyze(cat, plan)
    check("case-insensitive: albums to skip", r.summary.albumsToSkip, 1)
    check("case-insensitive: ancestors existing", r.summary.ancestorsExisting, 2)
end

-- ── duplicate target paths from two source plans ──────────────────────────
do
    local cat = makeCatalog()
    local plan = planFixture(
        { { "_archive" }, { "_archive", "Smith" } },
        {
            { parent = { "_archive", "Smith" }, name = "2024-03-15 - Wedding" },
            { parent = { "_archive", "Smith" }, name = "2024-03-15 - Wedding" }, -- dup
        }
    )
    local r = Preflight.analyze(cat, plan)
    -- Both sides of a duplicate are flagged so the user must resolve it
    check("dupe: total duplicates", r.summary.albumDuplicates, 2)
    local dupCount, createCount = 0, 0
    for _, a in ipairs(r.albums) do
        if a.status == "duplicate-target" then dupCount = dupCount + 1 end
        if a.status == "ok-create" then createCount = createCount + 1 end
    end
    check("dupe: dup status count", dupCount, 2)
    check("dupe: ok-create count", createCount, 0)
end

-- ── ancestor blocked by a collection (parent path conflict) ───────────────
do
    -- A collection named "Smith" exists where a set should be
    local wrongSmith = makeColl("Smith")
    local archive = makeSet("_archive", {}, { wrongSmith })
    local cat = makeCatalog({ archive })
    local plan = planFixture(
        { { "_archive" }, { "_archive", "Smith" } },
        { { parent = { "_archive", "Smith" }, name = "2024-03-15 - Wedding" } }
    )
    local r = Preflight.analyze(cat, plan)
    check("blocked: ancestor collisions", r.summary.ancestorCollisions, 1)
    -- Album also reports collision-parent because its parent path is blocked
    check("blocked: album collisions", r.summary.albumCollisions, 1)
    check("blocked: album status", r.albums[1].status, "collision-parent")
end

if failures > 0 then
    io.write(string.format("\n%d failure(s)\n", failures))
    os.exit(1)
end
io.write("\nall passed\n")
