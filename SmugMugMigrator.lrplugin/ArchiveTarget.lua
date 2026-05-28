--[[
    ArchiveTarget.lua — locate or create the top-level "_archive" collection
    set under which all migrated content will live.

    All catalog API calls assume they're running inside an LrTasks task.
--]]

local M = {}

local ARCHIVE_NAME = "_archive"

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

--- Find or create the _archive collection set at the root of the catalog.
-- Performs a single short writeAccessDo only when creation is necessary.
-- @param catalog LrCatalog
-- @param opts table optional { dryRun = boolean, logger }
-- @return setOrNil, info { existed, created, conflict, name }
function M.findOrCreate(catalog, opts)
    opts = opts or {}
    local logger = opts.logger

    local existing = findTopLevelSet(catalog, ARCHIVE_NAME)
    if existing then
        if logger then logger:info("Archive root set %q already exists.", ARCHIVE_NAME) end
        return existing, { existed = true, created = false, conflict = false, name = ARCHIVE_NAME }
    end

    local conflict = findTopLevelCollectionConflict(catalog, ARCHIVE_NAME)
    if conflict then
        if logger then
            logger:error("Cannot create %q: a top-level COLLECTION with that name already exists.",
                ARCHIVE_NAME)
        end
        return nil, { existed = false, created = false, conflict = true, name = ARCHIVE_NAME }
    end

    if opts.dryRun then
        if logger then logger:info("[dry-run] Would create root collection set %q.", ARCHIVE_NAME) end
        return nil, { existed = false, created = false, conflict = false, name = ARCHIVE_NAME, dryRun = true }
    end

    local createdSet
    catalog:withWriteAccessDo("Create _archive root", function()
        createdSet = catalog:createCollectionSet(ARCHIVE_NAME, nil, true)
    end)
    if logger then logger:info("Created root collection set %q.", ARCHIVE_NAME) end
    return createdSet, { existed = false, created = true, conflict = false, name = ARCHIVE_NAME }
end

M.NAME = ARCHIVE_NAME

return M

