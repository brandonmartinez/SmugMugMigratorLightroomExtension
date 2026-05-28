--[[
    Info.lua — Lightroom Classic plugin manifest for SmugMug Migrator.

    Registers a single Library > Plug-in Extras menu entry that launches
    MigrationMain.lua.
--]]

return {
    LrSdkVersion = 10.0,
    LrSdkMinimumVersion = 6.0,

    LrToolkitIdentifier = "com.brandonmartinez.smugmug-migrator",
    LrPluginName = "SmugMug to Collections Migrator",

    LrLibraryMenuItems = {
        {
            title = "Migrate SmugMug to Collections…",
            file = "MigrationMain.lua",
        },
    },

    VERSION = { major = 0, minor = 1, revision = 1, build = 0 },
}
