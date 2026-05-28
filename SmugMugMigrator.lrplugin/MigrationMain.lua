--[[
    MigrationMain.lua — entry point for the Library > Plug-in Extras menu.

    Wires together the modules into the end-to-end run:

      1. Show mode-selection dialog (outside the async task — no catalog
         calls there).
      2. Spawn the async task; everything below runs guarded by
         LrTasks.pcall (a coroutine-safe pcall — standard Lua pcall
         cannot wrap SDK calls that yield, e.g. catalog:withWriteAccessDo,
         and will raise "Yielding is not allowed within a C or metamethod
         call") with finally-style cleanup so the logger is always closed
         and the progress scope always ends.
--]]

local LrApplication     = import "LrApplication"
local LrTasks           = import "LrTasks"
local LrFunctionContext = import "LrFunctionContext"
local LrDialogs         = import "LrDialogs"
local LrProgressScope   = import "LrProgressScope"

local Logger             = require "Logger"
local ModeDialog         = require "ModeDialog"
local GuidedDialog       = require "GuidedDialog"
local ReportDialog       = require "ReportDialog"
local SmugMugDiscovery   = require "SmugMugDiscovery"
local Planner            = require "Planner"
local Preflight          = require "Preflight"
local ArchiveTarget      = require "ArchiveTarget"
local Migrator           = require "Migrator"

-- Step 1: mode selection (no catalog calls)
local choice = ModeDialog.choose()
if not choice then
    return  -- user cancelled
end
local mode = choice.mode
local rootName = choice.rootName or "_archive"

-- Step 2: async task
LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("MigrationMain.run", function(_)
        local logger
        local progress
        local fatalErr

        local function cleanup()
            if progress then
                pcall(function() progress:done() end)
                progress = nil
            end
            if logger then
                pcall(function() logger:close() end)
            end
        end

        local ok, err = LrTasks.pcall(function()
            logger = Logger.new()
            local pluginInfo = require "Info"
            local v = pluginInfo.VERSION or {}
            logger:info("Plugin start, mode=%s, version=%d.%d.%d.%d, rootSet=%q",
                mode, v.major or 0, v.minor or 0, v.revision or 0, v.build or 0, rootName)

            local catalog = LrApplication.activeCatalog()

            local service, info = SmugMugDiscovery.findService(catalog, { logger = logger })
            if not service then
                local reasonMsg
                if info.reason == "none" then
                    reasonMsg = "No SmugMug-like publish service was found in this catalog."
                elseif info.reason == "cancelled" then
                    reasonMsg = "Cancelled at service-selection step."
                else
                    reasonMsg = "Unable to determine SmugMug publish service."
                end
                logger:warn(reasonMsg)
                cleanup()
                LrDialogs.message("SmugMug Migrator", reasonMsg, "info")
                fatalErr = "early-exit"
                return
            end
            logger:info("Using publish service: %s (id=%s)", service:getName(), service:getPluginId())

            local walked = SmugMugDiscovery.walk(service)
            logger:info("Discovered %d album(s) in tree.", #walked.allAlbums)

            local plan, warnings = Planner.plan(walked, { archiveSetName = rootName })
            for _, w in ipairs(warnings) do
                logger:warn("[%s] %s", w.kind, w.message)
            end
            logger:info("Planned %d ancestor set(s), %d album(s).",
                #plan.ancestorSets, #plan.albums)

            local preflight = Preflight.analyze(catalog, plan,
                { logger = logger, warnings = warnings })

            -- Upfront _archive conflict check: if a top-level collection
            -- (not set) is already named "_archive", bail out cleanly
            -- before we start showing progress bars.
            if mode ~= "dryRun" then
                local _, archInfo = ArchiveTarget.findOrCreate(catalog,
                    { logger = logger, dryRun = true, name = rootName })
                if archInfo.conflict then
                    LrDialogs.message("SmugMug Migrator",
                        string.format("A top-level COLLECTION named %q already exists in this catalog. " ..
                            "Rename or remove it and rerun.", rootName), "critical")
                    fatalErr = "archive-conflict"
                    return
                end
            end

            if mode == "batch" then
                progress = LrProgressScope { title = "Migrating SmugMug → Collections" }
                progress:setCancelable(true)
            end

            local stats = Migrator.run(catalog, preflight, {
                mode     = mode,
                logger   = logger,
                guidedFn = (mode == "guided") and GuidedDialog.ask or nil,
                progress = progress,
            })

            if progress then progress:done(); progress = nil end

            local logPath = logger:path()
            logger:close()
            logger = nil
            ReportDialog.show(stats, preflight.summary, logPath, mode)
        end)

        if not ok then
            local errStr = tostring(err)
            if logger then
                pcall(function() logger:error("Fatal error: %s", errStr) end)
            end
            cleanup()
            LrDialogs.message("SmugMug Migrator — Fatal Error",
                "The migration failed:\n\n" .. errStr, "critical")
        else
            -- Defensive cleanup (already cleaned up on the happy path)
            cleanup()
        end
    end)
end)

