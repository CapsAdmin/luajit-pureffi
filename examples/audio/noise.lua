local audio = require("audio")
local dump = require("helpers.table_print").print
function audio.callback(buffer, num_samples)
    for i = 0, num_samples - 1 do
        buffer[i] = (math.random() * 2.0) - 1.0
    end
end

dump(audio.start())

require("threads").sleep(1000)

audio.stop()
