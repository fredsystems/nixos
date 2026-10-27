-- Bar widget for ../../../../shell/nixos-deploy-state.nix. The script prints
-- one JSON object whose `alt` is reboot | update | clean and whose `tooltip`
-- is the human-readable state; this widget only maps that onto a glyph.

local SCRIPT = "@deployState@"

local STATES = {
  reboot = { glyph = "refresh-alert", color = "error" },
  update = { glyph = "download", color = "#fab387" }, -- Catppuccin Mocha peach
  clean = { glyph = "circle-check", color = "#a6e3a1" }, -- Catppuccin Mocha green
}

local running = false

local function show(alt, tooltip)
  local state = STATES[alt] or STATES.update
  barWidget.setGlyph(state.glyph)
  barWidget.setGlyphColor(state.color)
  barWidget.setText("")
  barWidget.setTooltip(tooltip)
end

local function refresh()
  if running then
    return
  end
  running = true
  local started = noctalia.runAsync({ SCRIPT }, function(result)
    running = false
    if result.exitCode ~= 0 then
      show("update", "Deploy state script failed: " .. result.stderr)
      return
    end
    local decoded = noctalia.json.decode(result.stdout)
    if decoded == nil then
      show("update", "Deploy state script printed invalid JSON")
      return
    end
    show(decoded.alt, decoded.tooltip or "")
  end)
  if not started then
    running = false
    show("update", "Deploy state script could not be started")
  end
end

function update()
  noctalia.setUpdateInterval(60000)
  refresh()
end

function onClick()
  refresh()
end
