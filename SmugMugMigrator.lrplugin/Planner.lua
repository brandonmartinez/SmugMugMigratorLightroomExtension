--[[
    Planner.lua — pure-logic translation of a SmugMug publish-service tree
    into a target plan under "_archive".

    Public API:

      Planner.plan(walked, opts) -> plan, warnings

    Inputs:
      walked = { rootChildren = { node, ... }, allAlbums = {...} }  -- from
               SmugMugDiscovery.walk()
      opts   = { archiveSetName = "_archive", nameMapping = NameMapping }

    Outputs:

      plan = {
        archiveSetName = "_archive",
        ancestorSets = {           -- list of collection sets to ensure exist
          {
            path = { "_archive", "Smith" },  -- full path from catalog root
            name = "Smith",                  -- leaf name
            sourcePath = { "Client Download", "Smith" }, -- for reporting
          },
          ...
        },
        albums = {                 -- list of target collections to create
          {
            source = { name = "20240315 - Wedding",
                       sourcePath = { "Client Download", "Smith", "20240315 - Wedding" },
                       sdk = <LrPublishedCollection> },
            target = { name = "2024-03-15 - Wedding",
                       parentPath = { "_archive", "Smith" },
                       fullPath   = { "_archive", "Smith", "2024-03-15 - Wedding" } },
            transformed = true,
            warning = nil,         -- string when name mapping flagged
          },
          ...
        },
      }

      warnings = list of { kind = string, message = string }

    No SDK calls. Safe to unit-test without Lightroom.

    Rules:
      * The IMMEDIATE child set of the publish service whose trimmed name
        is "Client Download" is unwrapped — its children rebase onto
        _archive.
      * Galleries that appear at the publish-service root (no enclosing
        client folder) are still planned, landing directly under _archive,
        with a warning so the user can review.
      * Other folder names are passed through trim() and become matching
        collection sets at the same depth under _archive.
      * Gallery names go through NameMapping.mapGalleryName.
--]]

local NameMapping = require "NameMapping"

local Planner = {}

local function copy(t)
    local out = {}
    for _, v in ipairs(t) do table.insert(out, v) end
    return out
end

local function pushAncestor(seen, ancestorList, fullPath, leafName, sourcePath)
    local key = table.concat(fullPath, "/"):lower()
    if seen[key] then return end
    seen[key] = true
    table.insert(ancestorList, {
        path = fullPath,
        name = leafName,
        sourcePath = sourcePath,
    })
end

local function visit(node, parentTargetPath, parentSourcePath, plan, seenAncestors, warnings, opts)
    if node.kind == "set" then
        local mappedName = NameMapping.mapFolderName(node.name)
        if mappedName == "" then
            table.insert(warnings, {
                kind = "empty-folder-name",
                message = string.format(
                    "Folder %q has an empty/whitespace name; skipping its subtree.",
                    node.name
                ),
            })
            return
        end

        local targetPath = copy(parentTargetPath)
        table.insert(targetPath, mappedName)
        local sourcePath = copy(parentSourcePath)
        table.insert(sourcePath, node.name)

        pushAncestor(seenAncestors, plan.ancestorSets, targetPath, mappedName, sourcePath)

        for _, child in ipairs(node.children or {}) do
            visit(child, targetPath, sourcePath, plan, seenAncestors, warnings, opts)
        end
        return
    end

    if node.kind == "gallery" then
        local mapped = NameMapping.mapGalleryName(node.name)
        if mapped.warning then
            table.insert(warnings, { kind = "gallery-name", message = mapped.warning })
        end

        local sourcePath = copy(parentSourcePath)
        table.insert(sourcePath, node.name)
        local fullPath = copy(parentTargetPath)
        table.insert(fullPath, mapped.name)

        table.insert(plan.albums, {
            source = { name = node.name, sourcePath = sourcePath, sdk = node.sdk },
            target = {
                name = mapped.name,
                parentPath = copy(parentTargetPath),
                fullPath = fullPath,
            },
            transformed = mapped.transformed,
            warning = mapped.warning,
        })
        return
    end
end

--- Build a target plan from a walked SmugMug tree.
-- @param walked table from SmugMugDiscovery.walk()
-- @param opts table { archiveSetName = "_archive" }
-- @return plan, warnings
function Planner.plan(walked, opts)
    opts = opts or {}
    local archiveSetName = opts.archiveSetName or "_archive"

    local plan = {
        archiveSetName = archiveSetName,
        ancestorSets = {},
        albums = {},
    }
    local warnings = {}
    local seenAncestors = {}

    -- _archive itself is always an implicit ancestor.
    pushAncestor(seenAncestors, plan.ancestorSets, { archiveSetName }, archiveSetName, {})

    for _, node in ipairs(walked.rootChildren or {}) do
        if node.kind == "set" and NameMapping.isRootSkip(node.name) then
            -- Unwrap: re-parent its children directly onto _archive.
            for _, child in ipairs(node.children or {}) do
                visit(child, { archiveSetName }, { node.name }, plan, seenAncestors, warnings, opts)
            end
        elseif node.kind == "gallery" then
            -- Edge case: a published collection directly under the publish
            -- service root. Land it under _archive and warn.
            table.insert(warnings, {
                kind = "root-gallery",
                message = string.format(
                    "Published collection %q sits at the publish-service root with no enclosing folder; placing under %q.",
                    node.name, archiveSetName
                ),
            })
            visit(node, { archiveSetName }, {}, plan, seenAncestors, warnings, opts)
        else
            -- Any other top-level set: treat its name as a client folder.
            table.insert(warnings, {
                kind = "non-standard-root",
                message = string.format(
                    "Top-level folder %q is not named %q; treating it as a client folder.",
                    node.name, "Client Download"
                ),
            })
            visit(node, { archiveSetName }, {}, plan, seenAncestors, warnings, opts)
        end
    end

    return plan, warnings
end

return Planner
