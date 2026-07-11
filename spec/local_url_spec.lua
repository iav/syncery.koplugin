-- =============================================================================
-- spec/local_url_spec.lua
-- =============================================================================
--
-- Locks LocalUrl.build: host defaults to 127.0.0.1 and is overridable,
-- scheme normalises to http/https, port defaults to 8384 and falls back
-- to it outside 1024-65535 (the UI's makeNumericSetting bound + corrupt-
-- value safety).
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_local_url_spec_" .. tostring(os.time()))

local LocalUrl = require("syncery_transports/syncthing/local_url")


-- Happy paths: scheme + port carried through, host hardcoded.
h.assert_equal(LocalUrl.build("http", 8384), "http://127.0.0.1:8384",
    "http + default port")
h.assert_equal(LocalUrl.build("https", 9000), "https://127.0.0.1:9000",
    "https + custom port")
h.assert_equal(LocalUrl.build("http", "9000"), "http://127.0.0.1:9000",
    "string port coerced to number")

-- Defaults: missing scheme/port.
h.assert_equal(LocalUrl.build(nil, nil), "http://127.0.0.1:8384",
    "nil scheme + nil port → http + 8384")

-- Scheme normalisation: anything but "https" → "http".
h.assert_equal(LocalUrl.build("ftp", 8384), "http://127.0.0.1:8384",
    "unknown scheme → http")
h.assert_equal(LocalUrl.build("HTTPS", 8384), "http://127.0.0.1:8384",
    "scheme is case-sensitive: only exact 'https' upgrades")

-- Port out of range (or non-numeric) → default 8384.
h.assert_equal(LocalUrl.build("http", 80), "http://127.0.0.1:8384",
    "privileged port (<1024) → default")
h.assert_equal(LocalUrl.build("http", 70000), "http://127.0.0.1:8384",
    "port >65535 → default")
h.assert_equal(LocalUrl.build("https", 443), "https://127.0.0.1:8384",
    "443 is below the 1024 floor → default port, scheme kept")
h.assert_equal(LocalUrl.build("http", "abc"), "http://127.0.0.1:8384",
    "non-numeric port → default")


-- Host: custom host carried through with default / custom port.
h.assert_equal(LocalUrl.build("http", 8384, "syncthing.example.com"), "http://syncthing.example.com:8384",
    "custom hostname + default port")
h.assert_equal(LocalUrl.build("https", 9000, "192.168.1.100"), "https://192.168.1.100:9000",
    "custom IP + custom port")
h.assert_equal(LocalUrl.build("http", 8384, "localhost"), "http://localhost:8384",
    "localhost string works as host")

-- Host fallback: nil/empty → 127.0.0.1.
h.assert_equal(LocalUrl.build("http", 8384, nil), "http://127.0.0.1:8384",
    "nil host → 127.0.0.1")
h.assert_equal(LocalUrl.build("http", 8384, ""), "http://127.0.0.1:8384",
    "empty host → 127.0.0.1")

-- Host with nil port → default 8384 (host preserved).
h.assert_equal(LocalUrl.build("https", nil, "syncthing.example.com"), "https://syncthing.example.com:8384",
    "custom host + nil port → default port")
