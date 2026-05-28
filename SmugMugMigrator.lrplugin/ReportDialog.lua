--[[
    ReportDialog.lua — final summary dialog.

    Shows the stats from a migration run plus the path to the log file,
    with a button to reveal the log in the OS file browser.
--]]

local LrDialogs         = import "LrDialogs"
local LrView            = import "LrView"
local LrFunctionContext = import "LrFunctionContext"
local LrShell           = import "LrShell"
local LrPathUtils       = import "LrPathUtils"

local M = {}

local function row(f, label, value)
    return f:row {
        f:static_text { title = label, width = 280 },
        f:static_text { title = tostring(value), width = 80, alignment = "right" },
    }
end

function M.show(stats, preflightSummary, logPath, mode)
    return LrFunctionContext.callWithContext("ReportDialog.show", function(_)
        local f = LrView.osFactory()

        local rows = {
            spacing = f:control_spacing(),
        }

        if stats.aborted then
            table.insert(rows, f:static_text {
                title = "Run was aborted (by user or cancel).",
                font = "<system/bold>",
                text_color = import("LrColor")(0.7, 0, 0),
            })
            table.insert(rows, f:separator { fill_horizontal = 1 })
        end

        table.insert(rows, f:static_text { title = "Mode: " .. mode, font = "<system/bold>" })
        table.insert(rows, f:separator { fill_horizontal = 1 })

        table.insert(rows, row(f, "Collection sets created",                 stats.setsCreated))
        table.insert(rows, row(f, "Collection sets already present",         stats.setsExisting))
        table.insert(rows, row(f, "Collection set collisions",               stats.setCollisions))
        table.insert(rows, f:spacer { height = 6 })

        table.insert(rows, row(f, "Collections created",                     stats.collectionsCreated))
        table.insert(rows, row(f, "Collections skipped (already existed)",   stats.collectionsSkipped))
        table.insert(rows, row(f, "Empty galleries skipped",                 stats.emptyGalleriesSkipped or 0))
        table.insert(rows, row(f, "Collection collisions (wrong kind/etc)",  stats.collectionCollisions))
        table.insert(rows, row(f, "Collection duplicate-target conflicts",   stats.collectionDuplicates))
        table.insert(rows, f:spacer { height = 6 })

        table.insert(rows, row(f, "Photos added to collections",             stats.photosAdded))
        table.insert(rows, row(f, "Published photos that could not resolve", stats.photosFailed))
        table.insert(rows, row(f, "Album errors",                            stats.albumErrors))
        table.insert(rows, row(f, "Name/structure warnings",                 preflightSummary.warningCount))

        table.insert(rows, f:separator { fill_horizontal = 1 })
        table.insert(rows, f:static_text { title = "Log file:", font = "<system/bold>" })
        table.insert(rows, f:static_text { title = logPath, width = 540, height_in_lines = 2 })

        local contents = f:column(rows)

        local result = LrDialogs.presentModalDialog {
            title = "SmugMug Migrator — Summary",
            contents = contents,
            actionVerb = "Done",
            otherVerb  = "Reveal Log",
        }
        if result == "other" then
            LrShell.revealInShell(logPath)
        end
    end)
end

return M
