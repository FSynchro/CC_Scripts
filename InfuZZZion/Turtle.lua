-- Thaumcraft Infusion Turtle Worker
-- Handles item placement, retrieval, and altar discovery

local CHANNEL = 1742
local CATALYST_BLOCK = "thermalfoundation:storage"
local CATALYST_BLOCK_META = 8

-- State
local modem = peripheral.find("modem")
local manipulator = peripheral.find("manipulator")
local homePosition = nil
local tasks = {}
local isGloveTurtle = false
local turtleId = os.getComputerID()

if not modem then
    error("No wireless modem found! Please attach an ender modem.")
end

modem.open(CHANNEL)

-- GPS position
local function getPosition()
    local x, y, z = gps.locate(5)
    if not x then
        return nil
    end
    return {x = x, y = y, z = z}
end

-- Move to position
local function moveTo(target)
    local current = getPosition()
    if not current then
        print("ERROR: Cannot get GPS position!")
        return false
    end
    
    -- Move in Y first
    while current.y < target.y do
        if not turtle.up() then
            print("ERROR: Cannot move up")
            return false
        end
        current.y = current.y + 1
    end
    
    while current.y > target.y do
        if not turtle.down() then
            print("ERROR: Cannot move down")
            return false
        end
        current.y = current.y - 1
    end
    
    -- Move in X
    while current.x < target.x do
        -- Face east
        while true do
            local pos = getPosition()
            turtle.forward()
            local newPos = getPosition()
            if newPos.x > pos.x then
                turtle.back()
                break
            end
            turtle.back()
            turtle.turnRight()
        end
        
        turtle.forward()
        current.x = current.x + 1
    end
    
    while current.x > target.x do
        -- Face west
        while true do
            local pos = getPosition()
            turtle.forward()
            local newPos = getPosition()
            if newPos.x < pos.x then
                turtle.back()
                break
            end
            turtle.back()
            turtle.turnRight()
        end
        
        turtle.forward()
        current.x = current.x - 1
    end
    
    -- Move in Z
    while current.z < target.z do
        -- Face south
        while true do
            local pos = getPosition()
            turtle.forward()
            local newPos = getPosition()
            if newPos.z > pos.z then
                turtle.back()
                break
            end
            turtle.back()
            turtle.turnRight()
        end
        
        turtle.forward()
        current.z = current.z + 1
    end
    
    while current.z > target.z do
        -- Face north
        while true do
            local pos = getPosition()
            turtle.forward()
            local newPos = getPosition()
            if newPos.z < pos.z then
                turtle.back()
                break
            end
            turtle.back()
            turtle.turnRight()
        end
        
        turtle.forward()
        current.z = current.z - 1
    end
    
    return true
end

-- Return to home position
local function returnHome()
    if homePosition then
        print("Returning home...")
        moveTo(homePosition)
        
        modem.transmit(CHANNEL, CHANNEL, {
            type = "turtle_returned",
            data = {
                turtleId = turtleId
            }
        })
    end
end

-- Scan for catalyst pedestals
local function findCatalystPedestals()
    print("Scanning for catalyst pedestals...")
    local foundAltars = {}
    
    -- Scan area around turtle
    local scanRadius = 16
    local currentPos = getPosition()
    
    if not currentPos then
        print("ERROR: Cannot get GPS position for scanning")
        return
    end
    
    for dx = -scanRadius, scanRadius do
        for dy = -scanRadius, scanRadius do
            for dz = -scanRadius, scanRadius do
                local checkPos = {
                    x = currentPos.x + dx,
                    y = currentPos.y + dy,
                    z = currentPos.z + dz
                }
                
                -- Move to position
                if moveTo(checkPos) then
                    -- Check block below
                    local success, block = turtle.inspectDown()
                    if success and block.name == CATALYST_BLOCK and block.metadata == CATALYST_BLOCK_META then
                        print("Found catalyst pedestal at " .. textutils.serialize(checkPos))
                        
                        -- This is a catalyst pedestal, now find surrounding pedestals
                        local pedestals = findSurroundingPedestals(checkPos)
                        
                        table.insert(foundAltars, {
                            catalyst = checkPos,
                            pedestals = pedestals
                        })
                    end
                end
            end
        end
    end
    
    -- Return home
    returnHome()
    
    -- Report found altars
    for _, altar in ipairs(foundAltars) do
        modem.transmit(CHANNEL, CHANNEL, {
            type = "altar_found",
            data = {
                catalystPos = altar.catalyst,
                pedestalPositions = altar.pedestals
            }
        })
    end
end

-- Find pedestals around catalyst
local function findSurroundingPedestals(catalystPos)
    local pedestals = {}
    
    -- Pedestal layout pattern
    local pattern = {
        {x = 0, z = -4},  -- 1
        {x = 0, z = 4},   -- 2
        {x = -4, z = 0},  -- 3
        {x = 4, z = 0},   -- 4
        {x = -4, z = -4}, -- 5
        {x = 4, z = 4},   -- 6
        {x = 4, z = -4},  -- 7
        {x = -4, z = 4},  -- 8
        {x = -2, z = -4}, -- 9
        {x = 2, z = 4},   -- 10
        {x = 2, z = -4},  -- 11
        {x = -2, z = 4}   -- 12
    }
    
    for i, offset in ipairs(pattern) do
        local pedestalPos = {
            x = catalystPos.x + offset.x,
            y = catalystPos.y,
            z = catalystPos.z + offset.z
        }
        
        -- Move above pedestal
        local checkPos = {
            x = pedestalPos.x,
            y = pedestalPos.y + 1,
            z = pedestalPos.z
        }
        
        if moveTo(checkPos) then
            local success, block = turtle.inspectDown()
            if success and block.name and block.name:find("pedestal") then
                print("Found pedestal #" .. i)
                table.insert(pedestals, pedestalPos)
            end
        end
    end
    
    return pedestals
end

-- Check if near glove chest
local function checkGloveChest()
    -- TODO: Implement glove chest detection
    -- For now, return false
    return false
end

-- Place item on pedestal
local function placeItemOnPedestal(item, position)
    print("Placing item on pedestal at " .. textutils.serialize(position))
    
    -- Move above pedestal
    local targetPos = {
        x = position.x,
        y = position.y + 1,
        z = position.z
    }
    
    if not moveTo(targetPos) then
        print("ERROR: Cannot move to pedestal")
        return false
    end
    
    -- Use manipulator to get chest inventory
    local chest = peripheral.wrap("bottom") -- Assuming we're at the input chest level
    if not chest then
        print("ERROR: Cannot find chest")
        return false
    end
    
    -- Find item in chest
    local itemSlot = nil
    for slot, chestItem in pairs(chest.list()) do
        local detail = chest.getItemDetail(slot)
        if detail.name == item.name then
            -- Check NBT/DMG if needed
            local match = true
            if item.matchDMG and detail.damage ~= item.damage then
                match = false
            end
            if item.matchNBT and detail.nbt ~= item.nbt then
                match = false
            end
            
            if match then
                itemSlot = slot
                break
            end
        end
    end
    
    if not itemSlot then
        print("ERROR: Item not found in chest")
        return false
    end
    
    -- Move item from chest to pedestal
    -- First, we need to be at the pedestal
    moveTo(position)
    
    -- Get pedestal as peripheral
    local pedestal = peripheral.wrap("bottom")
    if not pedestal then
        print("ERROR: Cannot find pedestal")
        return false
    end
    
    -- Use manipulator to transfer
    if manipulator then
        manipulator.getInventory("bottom").pushItems(peripheral.getName(chest), itemSlot, 1, 1)
    end
    
    return true
end

-- Retrieve item from pedestal
local function retrieveItemFromPedestal(position)
    print("Retrieving item from pedestal at " .. textutils.serialize(position))
    
    -- Move to pedestal
    moveTo(position)
    
    -- Get pedestal
    local pedestal = peripheral.wrap("bottom")
    if not pedestal then
        print("ERROR: Cannot find pedestal")
        return false
    end
    
    -- Get ME Interface (we need to know its position - for now assume it's known)
    -- TODO: Get ME Interface position from server
    
    -- Transfer item
    if manipulator then
        -- Pull from pedestal
        local items = pedestal.list()
        for slot, item in pairs(items) do
            -- Push to ME Interface
            -- manipulator.getInventory("bottom").pushItems(meInterfaceName, slot, item.count)
        end
    end
    
    return true
end

-- Execute task
local function executeTask(task)
    print("Executing task: " .. task.type)
    
    if task.type == "place_catalyst" then
        return placeItemOnPedestal(task.item, task.position)
        
    elseif task.type == "place_ingredient" then
        return placeItemOnPedestal(task.item, task.position)
        
    elseif task.type == "retrieve_result" then
        return retrieveItemFromPedestal(task.position)
        
    end
    
    return false
end

-- Process tasks
local function processTasks()
    while #tasks > 0 do
        local task = table.remove(tasks, 1)
        
        local success = executeTask(task)
        
        -- Notify server
        modem.transmit(CHANNEL, CHANNEL, {
            type = "turtle_task_complete",
            data = {
                turtleId = turtleId,
                success = success
            }
        })
    end
    
    -- Return home
    returnHome()
end

-- Handle messages
local function handleMessage(msg)
    if type(msg) ~= "table" or not msg.type then return end
    
    if msg.type == "discover_altars" then
        findCatalystPedestals()
        
    elseif msg.type == "turtle_tasks" then
        if msg.data.turtleId == turtleId then
            tasks = msg.data.tasks
            processTasks()
        end
        
    elseif msg.type == "disaster_abort" then
        print("DISASTER ABORT! Stopping all tasks!")
        tasks = {}
        returnHome()
    end
end

-- Main loop
local function main()
    print("Thaumcraft Turtle Worker Starting...")
    print("Computer ID: " .. turtleId)
    
    -- Get home position
    homePosition = getPosition()
    if not homePosition then
        error("ERROR: Cannot get GPS position! Make sure GPS is set up.")
    end
    
    print("Home position: " .. textutils.serialize(homePosition))
    
    -- Check if this is a glove turtle
    isGloveTurtle = checkGloveChest()
    
    -- Register with server
    modem.transmit(CHANNEL, CHANNEL, {
        type = "turtle_register",
        data = {
            position = homePosition,
            isGloveTurtle = isGloveTurtle
        }
    })
    
    print("Registered with server")
    print("Waiting for tasks...")
    
    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent("modem_message")
        
        if channel == CHANNEL then
            handleMessage(message)
        end
    end
end

main()
