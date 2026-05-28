--[[
    Preflight.lua — classify a plan against the actual catalog state.

    Public API (must be called inside an LrTasks task):

      Preflight.analyze(catalog, plan, opts) -> result

    `plan` is the output of Planner.plan().

    `result` shape:

      {
        ancestors = {
          {
            plan = <plan.ancestorSets[i]>,
            status = "ok-exists" | "ok-create"
                   | "collision-collection"   -- a collection exists where a set should be
                   | "collision-parent",      -- an ancestor of this set is a collection
            existingSdk = <LrCollectionSet> | nil,
          },
          ...
        },
        albums = {
          {
            plan = <plan.albums[i]>,
            status = "ok-create" | "skip-existing"
                   | "collision-wrong-kind"   -- target exists as a collection set
                   | "collision-parent"       -- ancestor path conflict
                   | "duplicate-target",      -- multiple plans target same path
            existingSdk = <LrCollection> | nil,
            conflictingWithIndex = N | nil,   -- for duplicate-target
          },
          ...
        },
        summary = {
          ancestorsExisting, ancestorsToCreate, ancestorCollisions,
          albumsToCreate, albumsToSkip, albumCollisions, albumDuplicates,
          warningCount,
        },
      }

    All SDK reads go through small helpers so the module is easy to follow.
--]]

local Preflight = {}

local function lower(s) return string.lower(s or "") end

local function getChildSetByName(parent, name)
    for _, set in ipairs(parent:getChildCollectionSets() or {}) do
        if set:getName() == name then return set end
    end
    -- Case-insensitive fallback (Lightroom names are generally
    -- case-insensitive within the same parent; check that too).
    local lname = lower(name)
    for _, set in ipairs(parent:getChildCollectionSets() or {}) do
        if lower(set:getName()) == lname then return set end
    end
    return nil
end

local function getChildCollectionByName(parent, name)
    for _, coll in ipairs(parent:getChildCollections() or {}) do
        if coll:getName() == name then return coll end
    end
    local lname = lower(name)
    for _, coll in ipairs(parent:getChildCollections() or {}) do
        if lower(coll:getName()) == lname then return coll end
    end
    return nil
end

-- Walk path[1..n-1] from catalog root, returning (parent, missingAt) where:
--   parent = the deepest existing set on the path, or catalog if path is len 1
--   missingAt = index where the walk stopped (nil if walked through all)
--   blockedByCollection = true if the walk halted because an entry exists as a collection
local function walkToParent(catalog, path)
    local cursor = catalog
    for i = 1, #path - 1 do
        local segment = path[i]
        local set = getChildSetByName(cursor, segment)
        if set then
            cursor = set
        else
            -- Check whether the missing segment exists as a collection (kind conflict)
            local coll = getChildCollectionByName(cursor, segment)
            if coll then
                return cursor, i, true
            end
            return cursor, i, false
        end
    end
    return cursor, nil, false
end

local function classifyAncestor(catalog, ancestor)
    local path = ancestor.path
    local parent, missingAt, blocked = walkToParent(catalog, path)
    if missingAt then
        if blocked then
            return { plan = ancestor, status = "collision-parent" }
        end
        return { plan = ancestor, status = "ok-create" }
    end

    -- Parent is fully reached. Inspect leaf.
    local leaf = path[#path]
    local existingSet = getChildSetByName(parent, leaf)
    if existingSet then
        return { plan = ancestor, status = "ok-exists", existingSdk = existingSet }
    end
    local existingColl = getChildCollectionByName(parent, leaf)
    if existingColl then
        return { plan = ancestor, status = "collision-collection", existingSdk = existingColl }
    end
    return { plan = ancestor, status = "ok-create" }
end

local function classifyAlbum(catalog, album)
    local path = album.target.fullPath
    local parent, missingAt, blocked = walkToParent(catalog, path)
    if missingAt then
        if blocked then
            return { plan = album, status = "collision-parent" }
        end
        return { plan = album, status = "ok-create" }
    end

    local leaf = path[#path]
    local existingColl = getChildCollectionByName(parent, leaf)
    if existingColl then
        return { plan = album, status = "skip-existing", existingSdk = existingColl }
    end
    local existingSet = getChildSetByName(parent, leaf)
    if existingSet then
        return { plan = album, status = "collision-wrong-kind", existingSdk = existingSet }
    end
    return { plan = album, status = "ok-create" }
end

local function detectDuplicateTargets(albums)
    local seen = {}
    local dupes = {}
    for i, album in ipairs(albums) do
        local key = table.concat(album.target.fullPath, "/"):lower()
        if seen[key] then
            dupes[i] = seen[key]
            dupes[seen[key]] = seen[key]
        else
            seen[key] = i
        end
    end
    return dupes
end

--- Analyze a plan against the catalog.
-- @param catalog LrCatalog
-- @param plan table from Planner.plan
-- @param opts table optional { logger, warnings = warnings list from planner }
-- @return result table
function Preflight.analyze(catalog, plan, opts)
    opts = opts or {}
    local result = {
        ancestors = {},
        albums = {},
        summary = {
            ancestorsExisting   = 0,
            ancestorsToCreate   = 0,
            ancestorCollisions  = 0,
            albumsToCreate      = 0,
            albumsToSkip        = 0,
            albumCollisions     = 0,
            albumDuplicates     = 0,
            warningCount        = opts.warnings and #opts.warnings or 0,
        },
    }

    for _, ancestor in ipairs(plan.ancestorSets) do
        local entry = classifyAncestor(catalog, ancestor)
        table.insert(result.ancestors, entry)
        if entry.status == "ok-exists" then
            result.summary.ancestorsExisting = result.summary.ancestorsExisting + 1
        elseif entry.status == "ok-create" then
            result.summary.ancestorsToCreate = result.summary.ancestorsToCreate + 1
        else
            result.summary.ancestorCollisions = result.summary.ancestorCollisions + 1
        end
    end

    local dupes = detectDuplicateTargets(plan.albums)

    for i, album in ipairs(plan.albums) do
        local entry
        if dupes[i] then
            entry = { plan = album, status = "duplicate-target", conflictingWithIndex = dupes[i] }
        else
            entry = classifyAlbum(catalog, album)
        end
        table.insert(result.albums, entry)
        if entry.status == "ok-create" then
            result.summary.albumsToCreate = result.summary.albumsToCreate + 1
        elseif entry.status == "skip-existing" then
            result.summary.albumsToSkip = result.summary.albumsToSkip + 1
        elseif entry.status == "duplicate-target" then
            result.summary.albumDuplicates = result.summary.albumDuplicates + 1
        else
            result.summary.albumCollisions = result.summary.albumCollisions + 1
        end
    end

    if opts.logger then
        local s = result.summary
        opts.logger:info("Preflight: ancestors existing=%d create=%d collisions=%d",
            s.ancestorsExisting, s.ancestorsToCreate, s.ancestorCollisions)
        opts.logger:info("Preflight: albums create=%d skip=%d collisions=%d duplicates=%d",
            s.albumsToCreate, s.albumsToSkip, s.albumCollisions, s.albumDuplicates)
        opts.logger:info("Preflight: %d warning(s).", s.warningCount)
    end

    return result
end

return Preflight
