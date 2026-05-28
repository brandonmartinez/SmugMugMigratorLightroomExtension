--[[
    Migrator.lua — execute a preflight-classified plan against the catalog.

    Public API (must be called inside an LrTasks task):

      Migrator.run(catalog, preflightResult, opts) -> stats

    `opts`:
      mode      = "dryRun" | "batch" | "guided"   (required)
      logger    = Logger instance                  (required)
      guidedFn  = function(album, info) -> "create"|"skip"|"abort"  -- guided mode only
      progress  = LrProgressScope|nil

    Stats returned:
      {
        setsCreated, setsExisting, setCollisions,
        collectionsCreated, collectionsSkipped, collectionCollisions,
        collectionDuplicates,
        photosAdded, photosFailed, albumErrors,
        aborted,
      }

    Behaviour:
      * Ancestor sets are created lazily, one missing level per write
        gate, so we never inspect a freshly created set within the same
        write gate.
      * Each album's collection is created + populated in ONE per-album
        writeAccessDo with a TOCTOU re-check inside the gate.
      * Photo-resolution from publishedPhoto:getPhoto() happens BEFORE the
        write gate, wrapped in LrTasks.pcall (coroutine-safe).
      * Photos are de-duped by handle identity before addPhotos.
      * Dry-run does no SDK mutations; it logs what would happen.

    NOTE on pcall: All `pcall` wrappers around SDK calls in this file use
    `LrTasks.pcall` instead of Lua's standard `pcall`. Standard `pcall`
    cannot wrap any function that yields the coroutine — including most
    of the catalog mutation API (withWriteAccessDo, etc.) — and will
    raise "Yielding is not allowed within a C or metamethod call".
--]]

local LrTasks = import "LrTasks"

local Migrator = {}

local function joinPath(parts) return table.concat(parts, "/") end

-- Walk a target path through the catalog and return the SDK set at that
-- path. Returns nil if any intermediate is missing or wrong-kind.
local function resolveSet(catalog, path)
    local cursor = catalog
    for _, segment in ipairs(path) do
        local found
        for _, set in ipairs(cursor:getChildCollectionSets() or {}) do
            if set:getName() == segment then found = set; break end
        end
        if not found then
            -- Case-insensitive fallback
            local lseg = string.lower(segment)
            for _, set in ipairs(cursor:getChildCollectionSets() or {}) do
                if string.lower(set:getName()) == lseg then found = set; break end
            end
        end
        if not found then return nil end
        cursor = found
    end
    return cursor
end

-- Ensure an ancestor set exists at path. Creates missing levels one at a
-- time, each in its own short writeAccessDo, so we never inspect a freshly
-- created collection set within the same write gate.
-- @return resolvedSet, errorMessage
local function ensureSetCreated(catalog, path, logger, dryRun, stats)
    if #path == 0 then return nil, "empty path" end

    -- Fast path: fully exists already.
    local existing = resolveSet(catalog, path)
    if existing then return existing end

    if dryRun then
        logger:info("[dry-run] Would create collection set %q", joinPath(path))
        stats.setsCreated = stats.setsCreated + 1
        return nil
    end

    -- Create each missing level one at a time, exiting the write gate
    -- between each so subsequent SDK reads are reliable.
    for depth = 1, #path do
        local prefix = {}
        for i = 1, depth do table.insert(prefix, path[i]) end

        local atDepth = resolveSet(catalog, prefix)
        if not atDepth then
            -- The parent for this level is the set at depth-1 (or catalog
            -- when depth == 1). Both have getChildCollectionSets/
            -- getChildCollections, so the same code works.
            local parentPath = {}
            for i = 1, depth - 1 do table.insert(parentPath, path[i]) end
            local parent = (#parentPath == 0) and catalog or resolveSet(catalog, parentPath)
            if not parent then
                return nil, "Parent set not resolvable at " .. joinPath(parentPath)
            end

            local segment = path[depth]

            -- Collision detection: same-name child collection?
            for _, coll in ipairs(parent:getChildCollections() or {}) do
                if coll:getName() == segment
                    or string.lower(coll:getName()) == string.lower(segment) then
                    return nil, string.format(
                        "Collision: a collection named %q exists where a set is required (path: %s)",
                        segment, joinPath(prefix)
                    )
                end
            end

            local createOk, createErr = LrTasks.pcall(function()
                catalog:withWriteAccessDo("Create collection set " .. segment, function()
                    catalog:createCollectionSet(segment, parent, true)
                end)
            end)
            if not createOk then
                return nil, string.format("Failed to create set %q: %s", joinPath(prefix), tostring(createErr))
            end

            stats.setsCreated = stats.setsCreated + 1
            logger:info("Created collection set %q", joinPath(prefix))
        end
    end

    return resolveSet(catalog, path)
end

-- Collect LrPhoto handles from a published collection. Returns
-- (photos, failedCount).
local function resolvePhotos(publishedColl, logger)
    local photos = {}
    local failed = 0
    local published = publishedColl:getPublishedPhotos() or {}
    for _, pp in ipairs(published) do
        local ok, photo = LrTasks.pcall(function() return pp:getPhoto() end)
        if ok and photo then
            table.insert(photos, photo)
        else
            failed = failed + 1
            logger:warn("Published photo could not be resolved to a catalog photo: %s",
                tostring(photo or "(nil)"))
        end
    end
    return photos, failed
end

local function describeSource(sourcePath)
    return joinPath(sourcePath)
end

local function describeTarget(fullPath)
    return joinPath(fullPath)
end

local function processAlbum(catalog, entry, opts, stats)
    local logger  = opts.logger
    local plan    = entry.plan
    local mode    = opts.mode
    local dryRun  = (mode == "dryRun")

    local sourceLabel = describeSource(plan.source.sourcePath)
    local targetLabel = describeTarget(plan.target.fullPath)

    if entry.status == "skip-existing" then
        logger:info("SKIP existing collection: %s (target %s)", sourceLabel, targetLabel)
        stats.collectionsSkipped = stats.collectionsSkipped + 1
        return
    end

    if entry.status == "collision-wrong-kind" then
        logger:error("COLLISION (wrong kind) at %s: target exists as a collection set, not a collection.", targetLabel)
        stats.collectionCollisions = stats.collectionCollisions + 1
        return
    end

    if entry.status == "collision-parent" then
        logger:error("COLLISION (parent) for %s: an ancestor path of %s is a collection.", sourceLabel, targetLabel)
        stats.collectionCollisions = stats.collectionCollisions + 1
        return
    end

    if entry.status == "duplicate-target" then
        logger:error("DUPLICATE target %s: multiple source albums map to this path; resolve in SmugMug before re-running.", targetLabel)
        stats.collectionDuplicates = stats.collectionDuplicates + 1
        return
    end

    if entry.status ~= "ok-create" then
        logger:error("Unknown plan status %q for %s; skipping.", tostring(entry.status), sourceLabel)
        return
    end

    -- Resolve photos *before* the write gate.
    local photos, failedPhotos
    if dryRun then
        local pub = plan.source.sdk:getPublishedPhotos() or {}
        photos = pub
        failedPhotos = 0
    else
        photos, failedPhotos = resolvePhotos(plan.source.sdk, logger)
        -- Dedupe by photo userdata identity. Lightroom's collection model
        -- treats duplicates as a no-op, but we want accurate counts.
        local seen, deduped = {}, {}
        for _, p in ipairs(photos) do
            if not seen[p] then
                seen[p] = true
                table.insert(deduped, p)
            end
        end
        if #deduped ~= #photos then
            logger:warn("Deduped %d duplicate photo references in %s",
                #photos - #deduped, sourceLabel)
        end
        photos = deduped
    end
    local photoCount = #photos

    stats.photosFailed = stats.photosFailed + failedPhotos

    -- Guided mode: ask the user.
    if mode == "guided" and opts.guidedFn then
        local decision = opts.guidedFn(plan, {
            sourceLabel = sourceLabel,
            targetLabel = targetLabel,
            photoCount  = photoCount,
            failedPhotos = failedPhotos,
        })
        if decision == "skip" then
            logger:info("GUIDED skip: %s -> %s", sourceLabel, targetLabel)
            stats.collectionsSkipped = stats.collectionsSkipped + 1
            return
        elseif decision == "abort" then
            logger:warn("GUIDED abort by user after %s", sourceLabel)
            stats.aborted = true
            return
        end
    end

    if dryRun then
        logger:info("[dry-run] Would create collection %q under %s and add %d photos.",
            plan.target.name, joinPath(plan.target.parentPath), photoCount)
        stats.collectionsCreated = stats.collectionsCreated + 1
        stats.photosAdded = stats.photosAdded + photoCount
        return
    end

    -- Ensure ancestor set is in place.
    local okEnsure, parentOrNil, ensureErr = LrTasks.pcall(ensureSetCreated, catalog, plan.target.parentPath, logger, false, stats)
    if not okEnsure then
        logger:error("Failed to ensure parent set for %s: %s", targetLabel, tostring(parentOrNil))
        stats.albumErrors = stats.albumErrors + 1
        return
    end
    if ensureErr then
        logger:error("Failed to ensure parent set for %s: %s", targetLabel, tostring(ensureErr))
        stats.albumErrors = stats.albumErrors + 1
        return
    end
    local parent = parentOrNil or resolveSet(catalog, plan.target.parentPath)
    if not parent then
        logger:error("Internal error: parent set %s could not be resolved after creation.",
            joinPath(plan.target.parentPath))
        stats.albumErrors = stats.albumErrors + 1
        return
    end

    -- Create the collection and populate it in one write gate, with a
    -- TOCTOU re-check inside the gate to avoid accidentally adding photos
    -- to a collection that was created by something else between
    -- preflight and execution.
    local createdNew = false
    local ok, err = LrTasks.pcall(function()
        catalog:withWriteAccessDo("Create collection " .. plan.target.name, function()
            -- Re-check for an existing collection with this name
            for _, coll in ipairs(parent:getChildCollections() or {}) do
                if coll:getName() == plan.target.name
                    or string.lower(coll:getName()) == string.lower(plan.target.name) then
                    -- TOCTOU: appeared between preflight and now. Skip
                    -- and let outer code report it.
                    return
                end
            end
            -- Re-check for wrong-kind collision
            for _, set in ipairs(parent:getChildCollectionSets() or {}) do
                if set:getName() == plan.target.name
                    or string.lower(set:getName()) == string.lower(plan.target.name) then
                    error("Collision: a collection set with this name exists")
                end
            end

            local created = catalog:createCollection(plan.target.name, parent, false)
            if not created then
                error("createCollection returned nil for " .. plan.target.name)
            end
            if #photos > 0 then
                created:addPhotos(photos)
            end
            createdNew = true
        end)
    end)

    if not ok then
        logger:error("Failed to create %s: %s", targetLabel, tostring(err))
        stats.albumErrors = stats.albumErrors + 1
        return
    end

    if createdNew then
        logger:info("CREATED collection %s with %d photos (source: %s)", targetLabel, photoCount, sourceLabel)
        stats.collectionsCreated = stats.collectionsCreated + 1
        stats.photosAdded = stats.photosAdded + photoCount
    else
        logger:info("SKIP existing collection (TOCTOU): %s", targetLabel)
        stats.collectionsSkipped = stats.collectionsSkipped + 1
    end
end

--- Run the migration.
-- @param catalog LrCatalog
-- @param preflight Preflight result
-- @param opts table { mode, logger, guidedFn?, progress? }
-- @return stats
function Migrator.run(catalog, preflight, opts)
    opts = opts or {}
    assert(opts.logger, "Migrator.run requires opts.logger")
    assert(opts.mode == "dryRun" or opts.mode == "batch" or opts.mode == "guided",
        "Migrator.run: invalid mode " .. tostring(opts.mode))

    local stats = {
        setsCreated         = 0,
        setsExisting        = preflight.summary.ancestorsExisting,
        setCollisions       = preflight.summary.ancestorCollisions,
        collectionsCreated  = 0,
        collectionsSkipped  = 0,
        collectionCollisions = 0,
        collectionDuplicates = 0,
        photosAdded         = 0,
        photosFailed        = 0,
        albumErrors         = 0,
        aborted             = false,
    }

    local logger = opts.logger
    logger:info("Migration run started: mode=%s", opts.mode)

    -- In dry-run, we still report ancestor creation intentions but don't
    -- actually create anything.
    if opts.mode == "dryRun" then
        for _, a in ipairs(preflight.ancestors) do
            if a.status == "ok-create" then
                logger:info("[dry-run] Would create collection set %q", joinPath(a.plan.path))
                stats.setsCreated = stats.setsCreated + 1
            elseif a.status == "collision-collection" then
                logger:error("COLLISION (wrong kind) at set %s: a collection already exists there.",
                    joinPath(a.plan.path))
            elseif a.status == "collision-parent" then
                logger:error("COLLISION (parent) at set %s: an ancestor is a collection.",
                    joinPath(a.plan.path))
            end
        end
    else
        -- Batch/guided: log ancestor collisions up front so the user sees
        -- them in context, then let per-album processing handle the rest.
        for _, a in ipairs(preflight.ancestors) do
            if a.status == "collision-collection" then
                logger:error("COLLISION (wrong kind) at set %s: a collection already exists there.",
                    joinPath(a.plan.path))
            elseif a.status == "collision-parent" then
                logger:error("COLLISION (parent) at set %s: an ancestor is a collection.",
                    joinPath(a.plan.path))
            end
        end
    end

    -- Walk albums.
    local total = #preflight.albums
    for i, albumEntry in ipairs(preflight.albums) do
        if opts.progress and opts.progress:isCanceled() then
            stats.aborted = true
            logger:warn("User cancelled at album %d/%d.", i, total)
            break
        end
        if opts.progress then
            opts.progress:setCaption(string.format("(%d/%d) %s",
                i, total, describeTarget(albumEntry.plan.target.fullPath)))
            opts.progress:setPortionComplete(i - 1, total)
        end

        processAlbum(catalog, albumEntry, opts, stats)

        if stats.aborted then break end
    end

    if opts.progress then opts.progress:setPortionComplete(total, total) end

    logger:info("Migration run finished: setsCreated=%d collectionsCreated=%d collectionsSkipped=%d photosAdded=%d photosFailed=%d errors=%d aborted=%s",
        stats.setsCreated, stats.collectionsCreated, stats.collectionsSkipped,
        stats.photosAdded, stats.photosFailed, stats.albumErrors, tostring(stats.aborted))

    return stats
end

return Migrator
