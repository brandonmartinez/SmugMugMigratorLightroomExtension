--[[
    ModeDialog.lua — initial dialog that lets the user pick the run mode
    and the root collection set name.

    Returns { mode = "dryRun" | "batch" | "guided", rootName = string }
    on confirm, or nil if the user cancelled.

    Safe to call from inside an LrTasks task. Touches no catalog APIs.
--]]

local LrDialogs         = import "LrDialogs"
local LrView            = import "LrView"
local LrBinding         = import "LrBinding"
local LrFunctionContext = import "LrFunctionContext"

local M = {}

function M.choose()
    return LrFunctionContext.callWithContext("ModeDialog.choose", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)
        props.mode = "dryRun"
        props.rootName = "_archive"

        local contents = f:column {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:static_text {
                title = "Migrate SmugMug publish service into Lightroom collections.\nChoose a run mode:",
                height_in_lines = 2,
            },
            f:radio_button {
                title = "Dry-run — preview only, no changes",
                value = LrView.bind("mode"),
                checked_value = "dryRun",
            },
            f:radio_button {
                title = "Batch — perform the migration end-to-end",
                value = LrView.bind("mode"),
                checked_value = "batch",
            },
            f:radio_button {
                title = "Guided — confirm each collection before creating",
                value = LrView.bind("mode"),
                checked_value = "guided",
            },
            f:separator { fill_horizontal = 1 },
            f:row {
                f:static_text { title = "Root collection set name:", width = 200 },
                f:edit_field {
                    value = LrView.bind("rootName"),
                    width_in_chars = 24,
                    immediate = true,
                },
            },
            f:static_text {
                title = "All migrated content is placed under this top-level set.\nIf it already exists, it will be reused; otherwise it will be created.",
                height_in_lines = 2,
                text_color = import("LrColor")(0.4, 0.4, 0.4),
            },
        }

        local result = LrDialogs.presentModalDialog {
            title = "SmugMug Migrator",
            contents = contents,
            actionVerb = "Continue",
        }
        if result == "ok" then
            local rootName = props.rootName or ""
            rootName = rootName:gsub("^%s+", ""):gsub("%s+$", "")
            if rootName == "" then rootName = "_archive" end
            return { mode = props.mode, rootName = rootName }
        end
        return nil
    end)
end

return M
