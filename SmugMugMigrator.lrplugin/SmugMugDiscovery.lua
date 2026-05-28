--[[
    SmugMugDiscovery.lua — locate the SmugMug publish service and walk its
    tree.

    Public API (must be called inside an LrTasks task):

      M.findService(catalog, opts) -> publishService|nil, info
      M.walk(publishService) -> { rootChildren = { node, ... }, allAlbums }

    A `node` is one of:
      { kind = "set",     name = string, sdk = <LrPublishedCollectionSet>,
        children = { node, ... } }
      { kind = "gallery", name = string, sdk = <LrPublishedCollection> }

    `allAlbums` is a flat list of every published collection found in the
    tree, with the source-path breadcrumbs preserved for reporting:
      { sdk = <LrPublishedCollection>, name = string,
        sourcePath = { "Client Download", "Smith", "20240315 - Wedding" } }

    The "Client Download" skip is NOT applied here — this module returns the
    raw tree faithfully. Mapping/skipping happens in the planner so the
    preflight report can name what was skipped.
--]]

local LrDialogs         = import "LrDialogs"
local LrView            = import "LrView"
local LrBinding         = import "LrBinding"
local LrFunctionContext = import "LrFunctionContext"

local M = {}

local function containsSmugMug(s)
    if not s then return false end
    return string.find(string.lower(s), "smugmug", 1, true) ~= nil
end

local function pickFromList(matches)
    return LrFunctionContext.callWithContext("SmugMugDiscovery.pick", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)
        props.choice = 1

        local items = {}
        for i, svc in ipairs(matches) do
            local label = string.format("%s  (id: %s)", svc:getName(), svc:getPluginId())
            table.insert(items, { title = label, value = i })
        end

        local contents = f:column {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:static_text {
                title = "Multiple SmugMug-like publish services were found.\nPick the one to migrate from:",
                height_in_lines = 2,
            },
            f:popup_menu {
                items = items,
                value = LrView.bind("choice"),
                width = 480,
            },
        }

        local result = LrDialogs.presentModalDialog {
            title = "SmugMug Migrator — Select Publish Service",
            contents = contents,
        }
        if result == "ok" then
            return matches[props.choice]
        end
        return nil
    end)
end

--- Find the SmugMug publish service in the active catalog.
-- @param catalog LrCatalog
-- @param opts table optional { logger }
-- @return service|nil, info table
--   info.reason = "ok" | "none" | "cancelled"
--   info.count  = number of candidates discovered
function M.findService(catalog, opts)
    opts = opts or {}
    local logger = opts.logger

    local services = catalog:getPublishServices(nil) or {}
    local matches = {}
    for _, svc in ipairs(services) do
        local pid  = svc:getPluginId()
        local name = svc:getName()
        if containsSmugMug(pid) or containsSmugMug(name) then
            table.insert(matches, svc)
            if logger then
                logger:info("Discovered candidate publish service: name=%q pluginId=%q",
                    tostring(name), tostring(pid))
            end
        end
    end

    if #matches == 0 then
        return nil, { reason = "none", count = 0 }
    end
    if #matches == 1 then
        return matches[1], { reason = "ok", count = 1 }
    end

    local picked = pickFromList(matches)
    if not picked then
        return nil, { reason = "cancelled", count = #matches }
    end
    return picked, { reason = "ok", count = #matches }
end

local function walkSet(node, list, sourcePath)
    local children = {}

    for _, set in ipairs(node:getChildCollectionSets() or {}) do
        local setName = set:getName()
        local childPath = {}
        for _, p in ipairs(sourcePath) do table.insert(childPath, p) end
        table.insert(childPath, setName)
        local sub = walkSet(set, list, childPath)
        table.insert(children, { kind = "set", name = setName, sdk = set, children = sub })
    end

    for _, coll in ipairs(node:getChildCollections() or {}) do
        local collName = coll:getName()
        local fullPath = {}
        for _, p in ipairs(sourcePath) do table.insert(fullPath, p) end
        table.insert(fullPath, collName)
        table.insert(list, { sdk = coll, name = collName, sourcePath = fullPath })
        table.insert(children, { kind = "gallery", name = collName, sdk = coll })
    end

    return children
end

--- Walk a publish service and return its tree + flat list of galleries.
-- @param publishService LrPublishService
-- @return table { rootChildren = { node, ... }, allAlbums = { ... } }
function M.walk(publishService)
    local allAlbums = {}
    local rootChildren = walkSet(publishService, allAlbums, {})
    return { rootChildren = rootChildren, allAlbums = allAlbums }
end

return M
