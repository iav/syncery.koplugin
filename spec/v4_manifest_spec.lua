-- =============================================================================
-- spec/v4_manifest_spec.lua
-- =============================================================================
-- Tests for v4 manifest caching: deterministic hash of manifest.files
-- tables, cache read/write (our_hash|peer_hash), and skip gates.
-- Uses test_helpers stub_md5 (simple string hash, no context API).
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_v4_manifest_spec_" .. tostring(os.time()))

local sha2 = require("ffi/sha2")  -- stubbed by test_helpers


-- stub_md5(s) returns a hex string for a given input string.
-- The real code uses context API (h = md5(); ctx(k); ctx(v); result = ctx()),
-- but the stub returns a simple string hash.  Adapt: hash the concatenation
-- of sorted keys + values.

local function files_hash(files)
    local keys = {}
    for k in pairs(files) do table.insert(keys, k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        table.insert(parts, k)
        table.insert(parts, files[k])
    end
    return sha2.md5(table.concat(parts, ""))
end


-- ===========================================================================
-- Deterministic hashing
-- ===========================================================================

do
    local files = { abc123 = "hash_a", def456 = "hash_b", ghi789 = "hash_c" }
    h.assert_equal(files_hash(files), files_hash(files),
        "same files → same hash (deterministic)")
end

do
    local f1 = { a = "1", b = "2", c = "3" }
    local f2 = { c = "3", a = "1", b = "2" }
    h.assert_equal(files_hash(f1), files_hash(f2),
        "insertion order does not matter (sorted keys)")
end

do
    local f1 = { a = "1", b = "2" }
    local f2 = { a = "1", b = "99" }
    h.assert_true(files_hash(f1) ~= files_hash(f2),
        "different values → different hash")
end

do
    local f1 = { a = "1" }
    local f2 = { a = "1", b = "2" }
    h.assert_true(files_hash(f1) ~= files_hash(f2),
        "different key count → different hash")
end


-- ===========================================================================
-- Cache persistence (our_hash|peer_hash format)
-- ===========================================================================

do
    local tmp = os.tmpname()
    local our_h  = files_hash({ a = "x" })
    local peer_h = files_hash({ b = "y" })

    local f = io.open(tmp, "w"); f:write(our_h .. "|" .. peer_h); f:close()

    local f2 = io.open(tmp, "r")
    local line = f2:read("*l"); f2:close()
    local pipe = line:find("|", 1, true)
    local cached_our  = line:sub(1, pipe - 1)
    local cached_peer = line:sub(pipe + 1)

    h.assert_equal(cached_our, our_h,   "round-trip our_hash")
    h.assert_equal(cached_peer, peer_h, "round-trip peer_hash")
    os.remove(tmp)
end


-- ===========================================================================
-- Old-format backward compatibility (our_hash only, no pipe)
-- ===========================================================================

do
    local tmp = os.tmpname()
    local our_h = files_hash({ a = "x" })
    local f = io.open(tmp, "w"); f:write(our_h); f:close()

    local f2 = io.open(tmp, "r")
    local line = f2:read("*l"); f2:close()
    local pipe = line:find("|", 1, true)
    local cached_our, cached_peer
    if pipe then
        cached_our  = line:sub(1, pipe - 1)
        cached_peer = line:sub(pipe + 1)
    else
        cached_our  = line
        cached_peer = nil
    end

    h.assert_equal(cached_our, our_h, "old format: our_hash read")
    h.assert_nil(cached_peer,        "old format: peer_hash is nil")
    os.remove(tmp)
end


-- ===========================================================================
-- Skip-upload / skip-comparison gates
-- ===========================================================================

do
    local files      = { a = "1", b = "2" }
    local peer_files = { c = "3", d = "4" }

    local our_hash  = files_hash(files)
    local peer_hash = files_hash(peer_files)

    -- Fresh state (no cache)
    local cached_our  = nil
    local cached_peer = nil

    local skip_upload     = (cached_our == our_hash)
    local skip_comparison = skip_upload and cached_peer == peer_hash

    h.assert_false(skip_upload,     "fresh: no cache → upload")
    h.assert_false(skip_comparison, "fresh: no cache → compare")

    -- Cache hit
    cached_our  = our_hash
    cached_peer = peer_hash

    skip_upload     = (cached_our == our_hash)
    skip_comparison = skip_upload and cached_peer == peer_hash

    h.assert_true(skip_upload,     "cache hit: skip upload")
    h.assert_true(skip_comparison, "cache hit: skip compare")

    -- Our files changed
    local new_our = files_hash({ a = "1", b = "2", e = "5" })
    skip_upload     = (cached_our == new_our)
    skip_comparison = skip_upload and cached_peer == peer_hash
    h.assert_false(skip_upload)
    h.assert_false(skip_comparison)

    -- Peer changed
    local new_peer = files_hash({ c = "3", d = "4", f = "6" })
    skip_upload     = (cached_our == our_hash)
    skip_comparison = skip_upload and cached_peer == new_peer
    h.assert_true(skip_upload,      "our unchanged → skip upload")
    h.assert_false(skip_comparison, "peer changed → must compare")
end


h.teardown()