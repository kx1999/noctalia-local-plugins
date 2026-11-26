--!nonstrict
-- Spectra desktop / lock-screen widget.
--
-- Each instance runs its own `cava` for audio (plugin desktop widgets do not
-- get the shell's spectrum feed); Noctalia kills it with the widget. The
-- logic lives in lib/desktop_entry.luau so the self-test can drive it.
--
-- IPC (runtime only, not saved):
--   noctalia msg plugin kylex/spectra:desktop all shape radial
--   noctalia msg plugin kylex/spectra:desktop all next | prev | demo | reset | info

local DesktopEntry = require("./lib/desktop_entry.luau")

local entry = DesktopEntry.new(desktopWidget)

function update()
  entry.update()
end

function onIpc(event, payload)
  entry.onIpc(event, payload)
end

entry.start()
