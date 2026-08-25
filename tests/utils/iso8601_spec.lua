local Utils = require("avante.utils")

describe("parse_iso8601_epoch", function()
  it("parses fractional seconds, which ACP agents send", function()
    -- claude-agent-acp reports updatedAt as e.g. 2026-08-24T23:18:35.642Z
    assert.is_number(Utils.parse_iso8601_epoch("2026-08-24T23:18:35.642Z"))
  end)

  it("treats fractional seconds as equal to the whole second", function()
    assert.equals(
      Utils.parse_iso8601_epoch("2026-08-24T23:18:35Z"),
      Utils.parse_iso8601_epoch("2026-08-24T23:18:35.642Z")
    )
  end)

  it("parses a numeric UTC offset", function()
    assert.equals(
      Utils.parse_iso8601_epoch("2026-08-24T12:00:01Z"),
      Utils.parse_iso8601_epoch("2026-08-24T12:00:01+00:00")
    )
  end)

  it("honours a non-zero offset", function()
    local utc = Utils.parse_iso8601_epoch("2026-08-24T12:00:00Z")
    local behind = Utils.parse_iso8601_epoch("2026-08-24T12:00:00-05:00")

    assert.equals(5 * 3600, behind - utc)
  end)

  it("accepts a compact offset without a colon", function()
    assert.equals(
      Utils.parse_iso8601_epoch("2026-08-24T12:00:00-0500"),
      Utils.parse_iso8601_epoch("2026-08-24T12:00:00-05:00")
    )
  end)

  it("orders timestamps correctly", function()
    -- Sorting the thread picker depends on this.
    local newer = Utils.parse_iso8601_epoch("2026-08-24T23:18:35.642Z")
    local older = Utils.parse_iso8601_epoch("2026-08-24T23:14:34.779Z")

    assert.is_true(newer > older)
  end)

  it("returns a number so it can be compared with os.time fallbacks", function()
    -- Returning a string here would raise inside table.sort.
    assert.equals("number", type(Utils.parse_iso8601_epoch("2026-08-24T23:18:35.642Z")))
  end)

  it("returns nil for malformed input", function()
    assert.is_nil(Utils.parse_iso8601_epoch("garbage"))
    assert.is_nil(Utils.parse_iso8601_epoch("2026-08-24"))
    assert.is_nil(Utils.parse_iso8601_epoch(""))
    assert.is_nil(Utils.parse_iso8601_epoch(nil))
  end)
end)

describe("parse_iso8601_date", function()
  it("keeps returning a formatted string for existing callers", function()
    -- providers/claude.lua feeds this to datetime_diff textually.
    local result = Utils.parse_iso8601_date("2026-08-24T23:18:35Z")

    assert.equals("string", type(result))
    assert.is_not_nil(result:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$"))
  end)

  it("now accepts fractional seconds instead of failing", function()
    local result, err = Utils.parse_iso8601_date("2026-08-24T23:18:35.642Z")

    assert.is_nil(err)
    assert.equals("string", type(result))
  end)

  it("still reports an error for malformed input", function()
    local result, err = Utils.parse_iso8601_date("nonsense")

    assert.is_nil(result)
    assert.is_not_nil(err)
  end)
end)
