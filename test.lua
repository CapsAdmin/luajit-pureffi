local threads = require("threads")

-- Thread worker function - computes Game of Life for assigned rows
local function worker(input)
    local start_row = input.start_row
    local end_row = input.end_row
    local width = input.width
    local height = input.height
    local grid = input.grid
    
    -- Helper to count neighbors with wrapping
    local function count_neighbors(x, y)
        local count = 0
        for dy = -1, 1 do
            for dx = -1, 1 do
                if not (dx == 0 and dy == 0) then
                    -- Wrap around edges
                    local nx = ((x - 1 + dx) % width) + 1
                    local ny = ((y - 1 + dy) % height) + 1
                    if grid[ny][nx] == 1 then
                        count = count + 1
                    end
                end
            end
        end
        return count
    end
    
    -- Compute next state for assigned rows
    local result = {}
    for y = start_row, end_row do
        result[y] = {}
        for x = 1, width do
            local neighbors = count_neighbors(x, y)
            local cell = grid[y][x]
            
            -- Conway's rules
            if cell == 1 then
                result[y][x] = (neighbors == 2 or neighbors == 3) and 1 or 0
            else
                result[y][x] = (neighbors == 3) and 1 or 0
            end
        end
    end
    
    return result
end

-- Initialize
math.randomseed(os.time())
local width, height = 32, 32
local grid = {}

for y = 1, height do
    grid[y] = {}
    for x = 1, width do
        grid[y][x] = math.random() > 0.7 and 1 or 0  -- 30% alive
    end
end

-- Create 8 threads
local num_threads = 8
local rows_per_thread = height / num_threads  -- 4 rows each
local thread_pool = {}

for i = 1, num_threads do
    thread_pool[i] = threads.new(worker)
end

-- Display function
local function display_grid(g, generation)
    os.execute("clear")  -- Use "cls" on Windows
    print("Generation: " .. generation .. " | Press Ctrl+C to stop")
    print(string.rep("─", width))
    for y = 1, height do
        for x = 1, width do
            io.write(g[y][x] == 1 and "██" or "  ")
        end
        io.write("\n")
    end
    print(string.rep("─", width))
end

-- Simple sleep using busy wait (100ms for 10 FPS)
local function sleep(seconds)
   -- local start = os.clock()
 --   while os.clock() - start < seconds do end
end

-- Main loop
local generation = 0
while true do
    display_grid(grid, generation)
    
    -- Launch all threads with their assigned rows
    for i = 1, num_threads do
        local start_row = (i - 1) * rows_per_thread + 1
        local end_row = i * rows_per_thread
        
        thread_pool[i]:run({
            start_row = start_row,
            end_row = end_row,
            width = width,
            height = height,
            grid = grid
        })
    end
    
    -- Collect results and assemble new grid
    local new_grid = {}
    for i = 1, num_threads do
        local result = thread_pool[i]:join()
        for y, row in pairs(result) do
            new_grid[y] = row
        end
    end
    
    grid = new_grid
    generation = generation + 1
    
    -- Sleep for 100ms (10 FPS)
    sleep(0.1)
end