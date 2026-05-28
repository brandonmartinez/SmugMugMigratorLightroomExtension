--[[
    ModeDialog.lua — initial dialog that lets the user pick the run mode.

    Returns one of "dryRun" | "batch" | "guided" | nil (cancel).

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
        }

        local result = LrDialogs.presentModalDialog {
            title = "SmugMug Migrator",
            contents = contents,
            actionVerb = "Continue",
        }
        if result == "ok" then return props.mode end
        return nil
    end)
end

return M
