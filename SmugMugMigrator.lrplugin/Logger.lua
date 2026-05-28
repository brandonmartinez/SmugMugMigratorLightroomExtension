--[[
    Logger.lua — file-backed logger for the SmugMug migration run.

    Writes a timestamped log file under ~/Documents/SmugMugMigrator/. The
    file is opened lazily on the first log() call so dry-runs that produce
    no output still create a file (we want a paper trail of every run).
--]]

local LrPathUtils = import "LrPathUtils"
local LrFileUtils = import "LrFileUtils"
local LrDate      = import "LrDate"

local Logger = {}
Logger.__index = Logger

local LEVELS = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }

local function timestamp()
    return LrDate.timeToUserFormat(LrDate.currentTime(), "%Y-%m-%d %H:%M:%S")
end

local function filenameTimestamp()
    return LrDate.timeToUserFormat(LrDate.currentTime(), "%Y%m%d-%H%M%S")
end

--- Construct a logger.
-- @param opts table optional { dir = string, minLevel = "INFO" }
function Logger.new(opts)
    opts = opts or {}

    local dir = opts.dir
        or LrPathUtils.child(LrPathUtils.getStandardFilePath("documents"), "SmugMugMigrator")

    if not LrFileUtils.exists(dir) then
        LrFileUtils.createAllDirectories(dir)
    end

    local path = LrPathUtils.child(dir, "migration-" .. filenameTimestamp() .. ".log")

    local self = setmetatable({}, Logger)
    self._path = path
    self._minLevel = LEVELS[opts.minLevel or "INFO"] or LEVELS.INFO
    self._handle = nil
    self._counts = { DEBUG = 0, INFO = 0, WARN = 0, ERROR = 0 }
    return self
end

function Logger:_open()
    if self._handle then return end
    local f, err = io.open(self._path, "a")
    if not f then
        error("Logger: unable to open log file '" .. tostring(self._path) .. "': " .. tostring(err))
    end
    self._handle = f
    f:write(string.format("# SmugMug Migrator log — opened %s\n", timestamp()))
    f:flush()
end

function Logger:path()
    return self._path
end

function Logger:counts()
    return {
        debug = self._counts.DEBUG,
        info  = self._counts.INFO,
        warn  = self._counts.WARN,
        error = self._counts.ERROR,
    }
end

function Logger:log(level, fmt, ...)
    local lv = LEVELS[level] or LEVELS.INFO
    self._counts[level] = (self._counts[level] or 0) + 1
    if lv < self._minLevel then return end

    self:_open()
    local msg
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        msg = ok and formatted or (tostring(fmt) .. " [format error]")
    else
        msg = tostring(fmt)
    end

    self._handle:write(string.format("%s [%-5s] %s\n", timestamp(), level, msg))
    self._handle:flush()
end

function Logger:debug(fmt, ...) self:log("DEBUG", fmt, ...) end
function Logger:info(fmt, ...)  self:log("INFO",  fmt, ...) end
function Logger:warn(fmt, ...)  self:log("WARN",  fmt, ...) end
function Logger:error(fmt, ...) self:log("ERROR", fmt, ...) end

function Logger:close()
    if self._handle then
        self._handle:write(string.format("# Closed %s\n", timestamp()))
        self._handle:close()
        self._handle = nil
    end
end

return Logger
