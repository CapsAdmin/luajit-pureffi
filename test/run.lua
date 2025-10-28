do
    local threads = require("threads")

    local thread = threads.new(function(input) 
        assert(input == 1)
        return input + 1
    end)

    thread:run(1)

    local ret = thread:join()

    assert(ret == 2)
end