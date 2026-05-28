--[[
    NameMapping.lua — name transformations + skip rules.

    Two rules:

    1. The immediate child of the chosen SmugMug publish service whose
       trimmed name (case-insensitive) is "Client Download" is skipped;
       its children re-parent onto the _archive root.

    2. Published collection (gallery) names of the form "YYYYMMDD - Name"
       are rewritten to "YYYY-MM-DD - Name". The 8 digits are validated as
       a real calendar date; if they aren't, the name is left unchanged
       and a warning is emitted so the user can review.

    All functions are pure — no SDK calls.
--]]

local NameMapping = {}

local CLIENT_DOWNLOAD = "client download"

local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

--- Should this immediate-root collection set be skipped?
-- @param name string the publish collection set's name
-- @return boolean
function NameMapping.isRootSkip(name)
    return trim(name):lower() == CLIENT_DOWNLOAD
end

local function isLeapYear(y)
    return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
end

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function isValidDate(y, m, d)
    if m < 1 or m > 12 then return false end
    if d < 1 then return false end
    local maxDay = DAYS_IN_MONTH[m]
    if m == 2 and isLeapYear(y) then maxDay = 29 end
    return d <= maxDay
end

--- Map a gallery name to its target collection name.
-- @param name string source published collection name
-- @return table { name = string, warning = string|nil, transformed = boolean }
function NameMapping.mapGalleryName(name)
    local source = name or ""
    local y, m, d, rest = source:match("^(%d%d%d%d)(%d%d)(%d%d)(%s*%-%s*.+)$")
    if not y then
        return {
            name = source,
            warning = string.format(
                "Gallery name %q does not match YYYYMMDD - Name; copying verbatim.",
                source
            ),
            transformed = false,
        }
    end

    local yn, mn, dn = tonumber(y), tonumber(m), tonumber(d)
    if not isValidDate(yn, mn, dn) then
        return {
            name = source,
            warning = string.format(
                "Gallery name %q has invalid date %04d-%02d-%02d; copying verbatim.",
                source, yn, mn, dn
            ),
            transformed = false,
        }
    end

    return {
        name = string.format("%s-%s-%s%s", y, m, d, rest),
        warning = nil,
        transformed = true,
    }
end

--- Map a folder (publish collection set) name verbatim, with trim.
-- @param name string
-- @return string
function NameMapping.mapFolderName(name)
    return trim(name)
end

NameMapping._trim = trim
NameMapping._isValidDate = isValidDate

return NameMapping
