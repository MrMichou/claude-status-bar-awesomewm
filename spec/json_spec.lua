-- Specs for the pure-Lua JSON decoder shipped with the widget.
-- Run with: busted   (from the repo root; see .busted)
local json = require("linux.awesomewm.claude_status.json")

describe("json.decode", function()
  it("decodes a flat object", function()
    local v = json.decode('{"state":"thinking","ts":42}')
    assert.are.equal("thinking", v.state)
    assert.are.equal(42, v.ts)
  end)

  it("decodes nested objects and arrays", function()
    local v = json.decode('{"a":[1,2,{"b":true}],"c":{"d":null}}')
    assert.are.equal(1, v.a[1])
    assert.are.equal(true, v.a[3].b)
    assert.is_nil(v.c.d)
  end)

  it("decodes booleans and null", function()
    assert.are.equal(true, json.decode("true"))
    assert.are.equal(false, json.decode("false"))
    assert.is_nil(json.decode("null"))
  end)

  describe("numbers", function()
    it("integers, decimals, negatives and exponents", function()
      assert.are.equal(7, json.decode("7"))
      assert.are.equal(-3.5, json.decode("-3.5"))
      assert.are.equal(1000.0, json.decode("1e3"))
    end)
  end)

  describe("strings", function()
    it("handles common escapes", function()
      assert.are.equal('a\nb', json.decode([["a\nb"]]))
      assert.are.equal('say "hi"', json.decode([["say \"hi\""]]))
      assert.are.equal('c:\\x', json.decode([["c:\\x"]]))
    end)

    it("decodes \\uXXXX (BMP) into UTF-8", function()
      -- U+2026 HORIZONTAL ELLIPSIS, as used in the "Thinking…" label.
      -- string.char (not "\xNN") so the expectation is portable across Lua 5.1+/LuaJIT.
      local ellipsis = string.char(0xE2, 0x80, 0xA6)
      assert.are.equal(ellipsis, json.decode([["…"]]))
    end)
  end)

  describe("malformed input decodes to nil", function()
    -- The decoder is intentionally lenient: parse errors yield a bare nil (the same as
    -- a valid JSON null). Only a non-string argument is reported with a message.
    it("unterminated string", function() assert.is_nil(json.decode('"oops')) end)
    it("missing comma in array", function() assert.is_nil(json.decode('[1 2]')) end)
    it("unexpected character", function() assert.is_nil(json.decode('@')) end)

    it("non-string input returns nil + message", function()
      local v, e = json.decode(nil)
      assert.is_nil(v)
      assert.is_string(e)
    end)
  end)
end)

describe("json.encode", function()
  it("encodes a flat object with sorted keys", function()
    assert.are.equal('{"a":1,"b":true,"c":"x"}', json.encode({ c = "x", a = 1, b = true }))
  end)

  it("escapes quotes and backslashes in strings", function()
    assert.are.equal([[{"k":"a\"b\\c"}]], json.encode({ k = 'a"b\\c' }))
  end)

  it("skips nested tables and non-scalar values", function()
    assert.are.equal('{"keep":"yes"}', json.encode({ keep = "yes", drop = { 1, 2 } }))
  end)

  it("round-trips a settings table through decode", function()
    local settings = { style = "clawd", icon_size = 22, show_timer = true, brand = "#d97757" }
    local v = json.decode(json.encode(settings))
    assert.are.equal("clawd", v.style)
    assert.are.equal(22, v.icon_size)
    assert.are.equal(true, v.show_timer)
    assert.are.equal("#d97757", v.brand)
  end)

  it("non-table input returns nil + message", function()
    local v, e = json.encode("nope")
    assert.is_nil(v)
    assert.is_string(e)
  end)
end)
