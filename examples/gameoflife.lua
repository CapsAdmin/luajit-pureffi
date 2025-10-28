local threads = require("threads")
local terminal = require("terminal")

-- Initialize terminal
local term = terminal.WrapFile(io.stdin, io.stdout)

-- Use alternate screen buffer (no scrollback, cleaner)
term:UseAlternateScreen(true)

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

-- Initialize random seed
math.randomseed(os.time())

-- Get initial terminal size
local term_width, term_height = term:GetSize()
local width = math.floor(term_width / 2) - 1  -- Each cell is 2 chars wide
local height = term_height - 4  -- Reserve space for header/footer

-- Create grid with random initial state
local function create_grid(w, h)
    local grid = {}
    for y = 1, h do
        grid[y] = {}
        for x = 1, w do
            grid[y][x] = math.random() > 0.7 and 1 or 0  -- 30% alive
        end
    end
    return grid
end

local grid = create_grid(width, height)

-- Create thread pool (8 threads)
local num_threads = 8
local thread_pool = {}

for i = 1, num_threads do
    thread_pool[i] = threads.new(worker)
end

-- Display function using terminal module
local function display_grid(g, generation, w, h, tw, th)
    term:BeginFrame()  -- Start buffering
    
    term:SetCaretPosition(1, 1)
    -- Header
    term:PushForegroundColor(0.5, 0.8, 1.0)
    term:Write("Generation: " .. generation .. " | Size: " .. tw .. "x" .. th .. " | Ctrl+C to exit")
    term:PopAttribute()
    term:Write("\n")
    term:Write(string.rep("─", w * 2) .. "\n")
    
    -- Grid - with safety checks
    for y = 1, h do
        if g[y] then
            for x = 1, w do
                if g[y][x] == 1 then
                    term:ForegroundColor(50, 255, 76)  -- Green for alive cells
                    term:Write("██")
                elseif g[y][x] == 0 then
                    term:ForegroundColor(25, 25, 25)  -- Dark for dead cells
                    term:Write("··")
                else
                    -- Cell doesn't exist, show as dead
                    term:ForegroundColor(25, 25, 25)
                    term:Write("··")
                end
            end
        else
            -- Row doesn't exist, fill with dead cells
            term:ForegroundColor(25, 25, 25)
            for x = 1, w do
                term:Write("··")
            end
        end
        term:Write("\n")
    end
    
    -- Footer
    term:Write(string.rep("─", w * 2))
    term:Write("\n")
    
    term:EndFrame()  -- Flush all at once
end

-- Check for Ctrl+C
local should_exit = false

-- Main loop
local generation = 0
local last_width, last_height = term_width, term_height

-- Hide cursor for cleaner display
term:EnableCaret(false)

while not should_exit do
    -- Check for terminal resize
    local new_width, new_height = term:GetSize()
    if new_width ~= last_width or new_height ~= last_height then
        -- Terminal resized, restart simulation
        term_width, term_height = new_width, new_height
        width = math.floor(term_width / 2) - 1
        height = term_height - 4
        
        -- Ensure dimensions are valid
        if width < 1 then width = 1 end
        if height < 1 then height = 1 end
        
        grid = create_grid(width, height)
        generation = 0
        last_width, last_height = new_width, new_height
        
        -- Clear thread pool and recreate
        for i = 1, num_threads do
            thread_pool[i] = threads.new(worker)
        end
        
        -- Display the new grid and skip to next iteration
        -- This prevents running threads with mismatched dimensions
        display_grid(grid, generation, width, height, term_width, term_height)
        goto continue
    end
    
    display_grid(grid, generation, width, height, term_width, term_height)
    
    -- Check for Ctrl+C
    local event = term:ReadEvent()
    if event then
        if event.key == "c" and event.modifiers.ctrl then
            should_exit = true
            break
        end
    end
    
    -- Launch all threads with their assigned rows
    local rows_per_thread = math.floor(height / num_threads)
    for i = 1, num_threads do
        local start_row = (i - 1) * rows_per_thread + 1
        local end_row = math.min(i * rows_per_thread, height)
        
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
    -- Pre-initialize all rows
    for y = 1, height do
        new_grid[y] = {}
        for x = 1, width do
            new_grid[y][x] = 0  -- Default to dead cells
        end
    end
    
    -- Collect thread results
    for i = 1, num_threads do
        local result = thread_pool[i]:join()
        if result then
            for y, row in pairs(result) do
                new_grid[y] = row
            end
        end
    end
    
    grid = new_grid
    generation = generation + 1
    
    ::continue::
end

-- Cleanup
term:UseAlternateScreen(false)  -- Restore main screen
term:EnableCaret(true)
term:SetCaretPosition(1, 1)
term:NoAttributes()
term:Write("Game of Life ended. Goodbye!\n")
