--!nonstrict
-- Spectra bar widget.
--
-- Audio comes from Noctalia's own PipeWire spectrum: the host reads the
-- `audio_spectrum` / `audio_spectrum_bands` widget settings and calls
-- onAudioSpectrum(valuesCsv, stateCsv) with that many 0..1 bands (low -> high)
-- every spectrum frame. No external tools are needed. The logic lives in
-- lib/bar_entry.luau so the self-test can drive it.
--
-- IPC (runtime only, not saved):
--   noctalia msg plugin kylex/spectra:bar all shape radial
--   noctalia msg plugin kylex/spectra:bar all next | prev | demo | reset | info

local BarEntry = require("./lib/bar_entry.luau")

local entry = BarEntry.new(barWidget)

function onAudioSpectrum(valuesCsv, stateCsv)
  entry.onAudioSpectrum(valuesCsv, stateCsv)
end

function update()
  entry.update()
end

function onIpc(event, payload)
  entry.onIpc(event, payload)
end

entry.start()
