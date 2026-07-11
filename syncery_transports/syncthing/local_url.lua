-- =============================================================================
-- syncery_transports/syncthing/local_url.lua
-- =============================================================================
--
-- Builds the base URL of the Syncthing daemon that backs this device.
--
-- The host defaults to 127.0.0.1 (loopback).  Changing it to a remote
-- address is useful when Syncthing runs on a different host (container,
-- VM, LAN).  The port defaults to 8384 (Syncthing's GUI default) and is
-- overridable in the Advanced settings; values outside 1024-65535 fall
-- back to the default so a corrupt/missing persisted value never yields
-- a malformed URL.
--
-- The scheme is "http" by default; "https" is auto-detected by the connection
-- test (BasicSync serves the GUI over https) and persisted in Settings.
--
-- Pure + dependency-free so both Settings (real backend) and the manual
-- provider (injected settings_reader) can build the same URL, and so the logic
-- is directly unit-testable.
-- =============================================================================

local M = {}

local DEFAULT_PORT = 8384
local DEFAULT_HOST = "127.0.0.1"

function M.build(scheme, port, host)
    local s = (scheme == "https") and "https" or "http"
    local p = tonumber(port)
    if type(p) ~= "number" or p ~= p or p < 1024 or p > 65535 then
        p = DEFAULT_PORT
    end
    local h = (type(host) == "string" and host ~= "") and host or DEFAULT_HOST
    return string.format("%s://%s:%d", s, h, math.floor(p))
end

return M
