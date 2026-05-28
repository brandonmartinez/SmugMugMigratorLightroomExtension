--[[
    GuidedDialog.lua — per-album confirmation modal.

    Called from Migrator (outside withWriteAccessDo) when running in
    guided mode. Returns "create" | "skip" | "abort".
--]]

local LrDialogs         = import "LrDialogs"
local LrView            = import "LrView"
local LrFunctionContext = import "LrFunctionContext"

local M = {}

function M.ask(album, info)
    return LrFunctionContext.callWithContext("GuidedDialog.ask", function(_)
        local f = LrView.osFactory()

        local rows = { spacing = f:control_spacing() }
        table.insert(rows, f:static_text { title = "Source:", font = "<system/bold>" })
        table.insert(rows, f:static_text { title = info.sourceLabel, width = 540, height_in_lines = 1 })
        table.insert(rows, f:spacer { height = 6 })
        table.insert(rows, f:static_text { title = "Target:", font = "<system/bold>" })
        table.insert(rows, f:static_text { title = info.targetLabel, width = 540, height_in_lines = 1 })
        table.insert(rows, f:spacer { height = 6 })
        table.insert(rows, f:static_text { title = string.format("Photos: %d", info.photoCount) })

        if info.failedPhotos and info.failedPhotos > 0 then
            table.insert(rows, f:static_text {
                title = string.format("Skipped %d published photo(s) that could not be resolved.",
                    info.failedPhotos),
                text_color = import("LrColor")(0.7, 0.4, 0),
            })
        end
        if album.warning then
            table.insert(rows, f:static_text {
                title = "Note: " .. album.warning,
                width = 540, height_in_lines = 3,
            })
        end

        local contents = f:column(rows)

        local result = LrDialogs.presentModalDialog {
            title = "Confirm Collection Creation",
            contents = contents,
            actionVerb = "Create",
            cancelVerb = "Abort",
            otherVerb  = "Skip",
        }
        if result == "ok"     then return "create" end
        if result == "other"  then return "skip"   end
        return "abort"
    end)
end

return M
