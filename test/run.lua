do
    local threads = require("threads")

    local thread = threads.new(function(input) 
        assert(input == 1)
        print("!!")
        return input + 1
    end)

    thread:run(1)

    local ret = thread:join()

    assert(ret == 2)
end


do
    local threads = require("threads")

    local thread = threads.new(function(input) 
        error("Intentional Error")
    end)

    thread:run(1)

    local ret, err = thread:join()
    assert(err:find("Intentional Error"))
end