-- =============================================================================
-- syncery_transports/cloud/list.lua
-- =============================================================================
--
-- Cloud manifest functions for V4 Merkle-manifest sync.
-- Provides resolveBookPath, generateManifest, uploadManifest, and
-- downloadManifest.

local M = {}

local logger = require("logger")

--- Walk cloud_staging/, collect progress + annotations content per book,
--- hash the combined content, and return a manifest table.
function M.generateManifest(plugin)
    logger.info("Syncery: generateManifest started")
    local staging = plugin.state_dir .. "cloud_staging/"
    local lfs = require("libs/libkoreader-lfs")
    local sha2 = require("ffi/sha2")
    local SyncUtil = require("syncery_util")

    -- Bail early if staging directory does not exist
    local staging_attr = lfs.attributes(staging, "mode")
    local staging_files = 0
    if staging_attr == "directory" then
        for _ in lfs.dir(staging) do staging_files = staging_files + 1 end
    end
    logger.info("Syncery: generateManifest staging dir=" .. tostring(staging_attr or "missing") .. " files=" .. tostring(staging_files))
    if not staging_attr then
        return {
            device_id = SyncUtil.get_device_id(),
            ts = os.time(),
            files = {},
        }
    end

    -- Clean up temp files from previous crash
    for f in lfs.dir(staging) do
        if f:match("^syncery%-manifest%-") then
            os.remove(staging .. f)
        end
    end

    -- Step 1: Collect all staging file contents per book
    local book_files = {}
    for f in lfs.dir(staging) do
        local kind, book_id = f:match("^syncery%-(%a+)%-(.+)%.json$")
        if book_id and (kind == "progress" or kind == "annotations") then
            local fh = io.open(staging .. f, "rb")
            if fh then
                local content = fh:read("*a")
                fh:close()
                if content then
                    if not book_files[book_id] then
                        book_files[book_id] = {}
                    end
                    book_files[book_id][kind] = content
                end
            end
        end
    end

    -- Step 2: Hash combined (progress .. annotations) per book
    local files = {}
    for book_id, kinds in pairs(book_files) do
        local progress = kinds.progress or ""
        local annotations = kinds.annotations or ""
        local combined = progress .. "\0" .. annotations
        local h = sha2.md5
        local ctx = h()
        ctx(combined)
        local hash = ctx()
        logger.info("Syncery: generateManifest book_id=" .. tostring(book_id) .. " hash=" .. hash)
        files[book_id] = hash
    end

    return {
        device_id = SyncUtil.get_device_id(),
        ts = os.time(),
        files = files,
    }
end
function M.uploadManifest(plugin, provider, server, manifest)
    logger.info("Syncery: uploadManifest for device " .. tostring(manifest.device_id))
    local staging = plugin.state_dir .. "cloud_staging/"
    local temp_path = staging .. "syncery-manifest-" .. manifest.device_id .. ".txt"
    require("util").makePath(staging)

    local cjson = require("json")
    local json_str = cjson.encode(manifest)

    local fh, err = io.open(temp_path, "wb")
    if not fh then
        logger.warn("Syncery: cannot write manifest temp file:", err)
        return
    end
    fh:write(json_str)
    fh:close()

    local prev = provider.base
    provider.base = server
    local ok, code = pcall(provider.uploadFile, server.url, temp_path, nil, true)
    provider.base = prev

    os.remove(temp_path)
    logger.info("Syncery: manifest upload ok")

    if not ok or code ~= 200 then
        logger.warn("Syncery: manifest upload failed:", tostring(ok), code)
    end
end

--- Download a remote device's manifest from the cloud.
function M.downloadManifest(plugin, provider, server, device_id)
    logger.info("Syncery: downloadManifest for device " .. tostring(device_id))
    local staging = plugin.state_dir .. "cloud_staging/"
    local temp_path = staging .. "syncery-manifest-remote.txt"

    local remote_name = "syncery-manifest-" .. device_id .. ".txt"
    local remote_url = server.url .. "/" .. remote_name
    local ok, code, etag = pcall(provider.downloadFile, remote_url, temp_path)

    if not ok or code ~= 200 then
        os.remove(temp_path)
        return nil
    end

    local fh, err = io.open(temp_path, "rb")
    if not fh then
        os.remove(temp_path)
        return nil
    end

    local content = fh:read("*a")
    fh:close()
    os.remove(temp_path)

    if not content or content == "" then
        return nil
    end

    local cjson = require("json")
    local ok_d, manifest = pcall(cjson.decode, content)
    if not ok_d then
        logger.warn("Syncery: invalid remote manifest JSON")
        return nil
    end

    logger.info("Syncery: manifest downloaded ok for " .. tostring(device_id))
    return manifest
end

--- Resolve a book_id back to the local file path via the cloud staging file.
function M.resolveBookPath(plugin, book_id)
    local path = plugin.state_dir .. "cloud_staging/syncery-progress-"
        .. book_id .. ".json"
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a"); f:close()
    local ok, data = pcall(require("json").decode, content)
    if not ok or not data then return nil end
    local my_device = require("syncery_util").get_device_id()
    local my_entry = data.entries and data.entries[my_device]
    if my_entry and my_entry.file then return my_entry.file end
    for _, entry in pairs(data.entries or {}) do
        if entry.file then return entry.file end
    end
    return nil
end

return M
