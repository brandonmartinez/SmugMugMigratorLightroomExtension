--[[
    ArchiveTarget.lua — locate or create the top-level "_archive" collection
    set under which all migrated content will live.

    All catalog API calls assume they're running inside an LrTasks task.
--]]

local M = {}

local DEFAULT_NAME = "_archive"

local function eqi(a, b) return string.lower(a or "") == string.lower(b or "") end

local function findTopLevelSet(catalog, name)
    for _, set in ipairs(catalog:getChildCollectionSets() or {}) do
        if set:getName() == name then return set end
    end
    for _, set in ipairs(catalog:getChildCollectionSets() or {}) do
        if eqi(set:getName(), name) then return set end
    end
    return nil
end

local function findTopLevelCollectionConflict(catalog, name)
    for _, coll in ipairs(catalog:getChildCollections() or {}) do
        if eqi(coll:getName(), name) then return coll end
    end
    return nil
end

--- Find or create the archive root collection set at the root of the catalog.
-- Performs a single short writeAccessDo only when creation is necessary.
-- @param catalog LrCatalog
-- @param opts table optional { dryRun = boolean, logger, name = string }
-- @return setOrNil, info { existed, created, conflict, name }
function M.findOrCreate(catalog, opts)
    opts = opts or {}
    local logger = opts.logger
    local name = opts.name or DEFAULT_NAME

    local existing = findTopLevelSet(catalog, name)
    if existing then
        if logger then logger:info("Archive root set %q already exists.", name) end
        return existing, { existed = true, created = false, conflict = false, name = name }
    end

    local conflict = findTopLevelCollectionConflict(catalog, name)
    if conflict then
        if logger then
            logger:error("Cannot create %q: a top-level COLLECTION with that name already exists.",
                name)
        end
        return nil, { existed = false, created = false, conflict = true, name = name }
    end

    if opts.dryRun then
        if logger then logger:info("[dry-run] Would create root collection set %q.", name) end
        return nil, { existed = false, created = false, conflict = false, name = name, dryRun = true }
    end

    local createdSet
    catalog:withWriteAccessDo("Create " .. name .. " root", function()
        createdSet = catalog:createCollectionSet(name, nil, false)
    end)
    if logger then logger:info("Created root collection set %q.", name) end
    return createdSet, { existed = false, created = true, conflict = false, name = name }
end

M.NAME = DEFAULT_NAME

return M

