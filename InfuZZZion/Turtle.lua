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

-- Find chest and ME Interface positions
local function findChestPositions()
    print("Searching for input chest and ME Interface...")
    
    local searchRadius = 10
    local currentPos = getPosition()
    
    if not currentPos then
        print("ERROR: Cannot get GPS position")
        return
    end
    
    local chestPos = nil
    local mePos = nil
    
    -- Search nearby for chest
    for dx = -searchRadius, searchRadius do
        for dy = -searchRadius, searchRadius do
            for dz = -searchRadius, searchRadius do
                local checkPos = {
                    x = currentPos.x + dx,
                    y = currentPos.y + dy,
                    z = currentPos.z + dz
                }
                
                if moveTo(checkPos) then
                    -- Check for chest below
                    local success, block = turtle.inspectDown()
                    if success and block.name and block.name:find("chest") then
                        print("Found chest at " .. textutils.serialize(checkPos))
                        chestPos = {x = checkPos.x, y = checkPos.y - 1, z = checkPos.z}
                        
                        -- ME Interface should be on opposite side of chest
                        -- Try each direction
                        for _, dir in ipairs({{1,0,0}, {-1,0,0}, {0,0,1}, {0,0,-1}}) do
                            local testPos = {
                                x = chestPos.x + dir[1],
                                y = chestPos.y,
                                z = chestPos.z + dir[3]
                            }
                            
                            local aboveTest = {x = testPos.x, y = testPos.y + 1, z = testPos.z}
                            if moveTo(aboveTest) then
                                local meSuccess, meBlock = turtle.inspectDown()
                                if meSuccess and meBlock.name and meBlock.name:find("interface") then
                                    print("Found ME Interface at " .. textutils.serialize(testPos))
                                    mePos = testPos
                                    break
                                end
                            end
                        end
                        
                        if chestPos and mePos then
                            break
                        end
                    end
                end
                
                if chestPos and mePos then break end
            end
            if chestPos and mePos then break end
        end
        if chestPos and mePos then break end
    end
    
    -- Return home
    returnHome()
    
    -- Report positions
    if chestPos and mePos then
        modem.transmit(CHANNEL, CHANNEL, {
            type = "chest_positions_found",
            data = {
                chestPosition = chestPos,
                meInterfacePosition = mePos
            }
        })
    else
        print("ERROR: Could not find chest and/or ME Interface")
    end
end

-- Check if near glove chest
local function checkGloveChest()
    -- TODO: Implement glove chest detection
    -- For now, return false
    return false
end

-- Place item on pedestal
local function placeItemOnPedestal(item, position, chestPosition)
    print("Placing item on pedestal at " .. textutils.serialize(position))
    
    -- First, move to Y level above the chest
    local chestAbovePos = {
        x = chestPosition.x,
        y = chestPosition.y + 1,
        z = chestPosition.z
    }
    
    if not moveTo(chestAbovePos) then
        print("ERROR: Cannot move above chest")
        return false
    end
    
    -- Get chest below us
    local chest = peripheral.wrap("bottom")
    if not chest or not chest.list then
        print("ERROR: Cannot find chest below")
        return false
    end
    
    -- Find item in chest
    local itemSlot = nil
    for slot, chestItem in pairs(chest.list()) do
        local detail = chest.getItemDetail(slot)
        if detail and detail.name == item.item.name then
            -- Check NBT/DMG if needed
            local match = true
            if item.matchDMG and (detail.damage or 0) ~= (item.item.damage or 0) then
                match = false
            end
            if item.matchNBT and (detail.nbt or "") ~= (item.item.nbt or "") then
                match = false
            end
            
            if match then
                itemSlot = slot
                break
            end
        end
    end
    
    if not itemSlot then
        print("ERROR: Item not found in chest: " .. item.item.name)
        return false
    end
    
    -- Suck item from chest into turtle
    if not turtle.suckDown(1) then
        print("ERROR: Cannot suck item from chest")
        return false
    end
    
    print("Picked up item from chest")
    
    -- Move up one more level (to be 2 blocks above chest, 1 above pedestal)
    if not turtle.up() then
        print("ERROR: Cannot move up from chest")
        return false
    end
    
    -- Now move to position above the pedestal (Y+1 above pedestal level)
    local pedestalAbovePos = {
        x = position.x,
        y = position.y + 1,
        z = position.z
    }
    
    if not moveTo(pedestalAbovePos) then
        print("ERROR: Cannot move to pedestal")
        return false
    end
    
    -- Drop item onto pedestal below
    if not turtle.dropDown(1) then
        print("ERROR: Cannot drop item onto pedestal")
        return false
    end
    
    print("Item placed on pedestal!")
    return true
end

-- Retrieve item from pedestal
local function retrieveItemFromPedestal(position, meInterfacePosition)
    print("Retrieving item from pedestal at " .. textutils.serialize(position))
    
    -- Move to position above pedestal (Y+1)
    local pedestalAbovePos = {
        x = position.x,
        y = position.y + 1,
        z = position.z
    }
    
    if not moveTo(pedestalAbovePos) then
        print("ERROR: Cannot move to pedestal")
        return false
    end
    
    -- Suck item from pedestal below
    if not turtle.suckDown(1) then
        print("ERROR: Cannot suck item from pedestal (may be empty)")
        return false
    end
    
    print("Picked up result item")
    
    -- Move to position above ME Interface
    local meAbovePos = {
        x = meInterfacePosition.x,
        y = meInterfacePosition.y + 1,
        z = meInterfacePosition.z
    }
    
    if not moveTo(meAbovePos) then
        print("ERROR: Cannot move to ME Interface")
        return false
    end
    
    -- Drop item into ME Interface below
    if not turtle.dropDown(1) then
        print("ERROR: Cannot drop item into ME Interface")
        return false
    end
    
    print("Result deposited into ME Interface!")
    return true
end

-- Execute task
local function executeTask(task)
    print("Executing task: " .. task.type)
    
    if task.type == "place_catalyst" then
        return placeItemOnPedestal(task.item, task.position, task.chestPosition)
        
    elseif task.type == "place_ingredient" then
        return placeItemOnPedestal(task.item, task.position, task.chestPosition)
        
    elseif task.type == "retrieve_result" then
        return retrieveItemFromPedestal(task.position, task.meInterfacePosition)
        
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
    
    if msg.type == "find_chest_positions" then
        findChestPositions()
        
    elseif msg.type == "discover_altars" then
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
