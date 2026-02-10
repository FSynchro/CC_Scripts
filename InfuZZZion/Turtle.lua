-- Thaumcraft Infusion Turtle Worker v2.0
-- Handles item placement, retrieval, and altar discovery

local CHANNEL = 1742
local PEDESTAL_BLOCK = "Thaumcraft:blockPedestal" -- Adjust based on actual block ID

-- State
local modem = peripheral.find("modem")
local homePosition = nil
local tasks = {}
local turtleId = nil
local assignedId = nil
local chestPosition = nil
local meInterfacePosition = nil

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
    return {x = math.floor(x), y = math.floor(y), z = math.floor(z)}
end

-- Send status update to server
local function updateStatus(status, statusDetail)
    modem.transmit(CHANNEL, CHANNEL, {
        type = "turtle_status_update",
        data = {
            turtleId = assignedId,
            status = status,
            statusDetail = statusDetail
        }
    })
end

-- Fuel management
local MIN_FUEL = 200
local REFUEL_THRESHOLD = 50

local function checkFuel()
    -- Try to refuel from internal inventory first
    if turtle.getFuelLevel() < MIN_FUEL then
        for i = 1, 16 do
            turtle.select(i)
            if turtle.refuel(0) then
                turtle.refuel()
                print("Refueled! Current level: " .. turtle.getFuelLevel())
            end
        end
    end
    
    -- Critical fuel warning
    if turtle.getFuelLevel() < REFUEL_THRESHOLD then
        if meInterfacePosition then
            print("CRITICAL FUEL: Going to ME Interface for coal...")
            updateStatus("refueling", "critical fuel level")
            
            local target = {
                x = meInterfacePosition.x,
                y = meInterfacePosition.y + 1,
                z = meInterfacePosition.z
            }
            
            if moveTo(target, true) then
                turtle.suckDown(16)
                turtle.refuel()
                print("Emergency refuel complete.")
                return true
            end
        else
            print("CRITICAL FUEL: No ME Interface known!")
        end
    end
    
    return turtle.getFuelLevel() > REFUEL_THRESHOLD
end

-- Movement with fuel check
local function moveTo(target, bypassFuel)
    if not bypassFuel and not checkFuel() then
        print("STALLED: Waiting for fuel...")
        return false
    end
    
    local current = getPosition()
    if not current then return false end
    
    if turtle.getFuelLevel() < 10 then
        print("ERROR: Out of fuel!")
        return false
    end
    
    -- Direction alignment helper
    local function align(axis, targetCoord)
        local attempts = 0
        while attempts < 4 do
            local p1 = getPosition()
            
            if not turtle.forward() then
                turtle.dig()
                if not turtle.forward() then 
                    return false 
                end
            end
            
            local p2 = getPosition()
            turtle.back()
            
            local success = false
            if axis == "x" then
                if targetCoord > p1.x and p2.x > p1.x then success = true end
                if targetCoord < p1.x and p2.x < p1.x then success = true end
            elseif axis == "z" then
                if targetCoord > p1.z and p2.z > p1.z then success = true end
                if targetCoord < p1.z and p2.z < p1.z then success = true end
            end
            
            if success then return true end
            
            turtle.turnRight()
            attempts = attempts + 1
        end
        return false
    end
    
    -- Move X
    if current.x ~= target.x then
        align("x", target.x)
        while current.x ~= target.x do
            if current.x < target.x then
                if not turtle.forward() then
                    turtle.dig()
                    if not turtle.forward() then break end
                end
                current.x = current.x + 1
            else
                turtle.turnRight()
                turtle.turnRight()
                if not turtle.forward() then
                    turtle.dig()
                    if not turtle.forward() then break end
                end
                current.x = current.x - 1
                turtle.turnRight()
                turtle.turnRight()
            end
        end
    end
    
    -- Move Z
    if current.z ~= target.z then
        align("z", target.z)
        while current.z ~= target.z do
            if current.z < target.z then
                if not turtle.forward() then
                    turtle.dig()
                    if not turtle.forward() then break end
                end
                current.z = current.z + 1
            else
                turtle.turnRight()
                turtle.turnRight()
                if not turtle.forward() then
                    turtle.dig()
                    if not turtle.forward() then break end
                end
                current.z = current.z - 1
                turtle.turnRight()
                turtle.turnRight()
            end
        end
    end
    
    -- Move Y
    while current.y > target.y do
        if not turtle.down() then
            turtle.digDown()
            if not turtle.down() then break end
        end
        current.y = current.y - 1
    end
    
    while current.y < target.y do
        if not turtle.up() then
            turtle.digUp()
            if not turtle.up() then break end
        end
        current.y = current.y + 1
    end
    
    return true
end

-- Return to home position
local function returnHome()
    if homePosition then
        print("Returning home...")
        updateStatus("returning", "going to home position")
        moveTo(homePosition)
        updateStatus("idle", "waiting")
        
        modem.transmit(CHANNEL, CHANNEL, {
            type = "turtle_returned",
            data = {
                turtleId = assignedId
            }
        })
    end
end

-- Scan for infusion altars
local function scanForAltars()
    print("Scanning for infusion altars...")
    updateStatus("scanning", "detecting infusion pedestals")
    
    local foundAltars = {}
    local scanRadius = 20
    local currentPos = getPosition()
    
    if not currentPos then
        print("ERROR: Cannot get GPS position for scanning")
        return
    end
    
    local scannedPedestals = {}
    
    -- Scan in a grid pattern
    for dy = -5, 5 do -- Check multiple Y levels
        for dx = -scanRadius, scanRadius, 2 do
            for dz = -scanRadius, scanRadius, 2 do
                local checkPos = {
                    x = currentPos.x + dx,
                    y = currentPos.y + dy,
                    z = currentPos.z + dz
                }
                
                -- Move above position
                local abovePos = {
                    x = checkPos.x,
                    y = checkPos.y + 1,
                    z = checkPos.z
                }
                
                if moveTo(abovePos) then
                    local success, block = turtle.inspectDown()
                    
                    if success and block.name and block.name:find("edestal") then
                        -- Found a pedestal
                        local pedestalPos = {
                            x = checkPos.x,
                            y = checkPos.y,
                            z = checkPos.z
                        }
                        
                        -- Check if already scanned
                        local alreadyScanned = false
                        for _, p in ipairs(scannedPedestals) do
                            if p.x == pedestalPos.x and p.y == pedestalPos.y and p.z == pedestalPos.z then
                                alreadyScanned = true
                                break
                            end
                        end
                        
                        if not alreadyScanned then
                            table.insert(scannedPedestals, pedestalPos)
                            print("Found pedestal at " .. textutils.serialize(pedestalPos))
                        end
                    end
                end
            end
        end
    end
    
    -- Group pedestals into altars (7x7 grid, same Y level)
    print("Grouping pedestals into altars...")
    local processed = {}
    
    for _, pedestal in ipairs(scannedPedestals) do
        local key = pedestal.x .. "," .. pedestal.y .. "," .. pedestal.z
        if not processed[key] then
            -- Try to find altar centered here or nearby
            local possibleCenters = {
                {x = pedestal.x, z = pedestal.z},
                {x = pedestal.x + 4, z = pedestal.z},
                {x = pedestal.x - 4, z = pedestal.z},
                {x = pedestal.x, z = pedestal.z + 4},
                {x = pedestal.x, z = pedestal.z - 4}
            }
            
            for _, center in ipairs(possibleCenters) do
                local altarPedestals = {}
                local catalystPos = {x = center.x, y = pedestal.y, z = center.z}
                
                -- Check if pedestals exist in 7x7 pattern around center
                local pattern = {
                    {x = 0, z = -4}, {x = 0, z = 4},
                    {x = -4, z = 0}, {x = 4, z = 0},
                    {x = -4, z = -4}, {x = 4, z = 4},
                    {x = 4, z = -4}, {x = -4, z = 4}
                }
                
                local found = 0
                for _, offset in ipairs(pattern) do
                    local testPos = {
                        x = catalystPos.x + offset.x,
                        y = catalystPos.y,
                        z = catalystPos.z + offset.z
                    }
                    
                    for _, p in ipairs(scannedPedestals) do
                        if p.x == testPos.x and p.y == testPos.y and p.z == testPos.z then
                            table.insert(altarPedestals, testPos)
                            found = found + 1
                            break
                        end
                    end
                end
                
                -- If we found at least 4 pedestals in the pattern, it's likely an altar
                if found >= 4 then
                    print("Found altar at " .. textutils.serialize(catalystPos) .. " with " .. found .. " pedestals")
                    
                    -- Mark all as processed
                    for _, p in ipairs(altarPedestals) do
                        local k = p.x .. "," .. p.y .. "," .. p.z
                        processed[k] = true
                    end
                    
                    -- Report to server
                    modem.transmit(CHANNEL, CHANNEL, {
                        type = "altar_found",
                        data = {
                            catalystPos = catalystPos,
                            pedestalPositions = altarPedestals,
                            turtleId = assignedId
                        }
                    })
                    
                    break
                end
            end
        end
    end
    
    returnHome()
    print("Altar scan complete")
end

-- Place item on pedestal
local function placeItemOnPedestal(item, position, chestPos)
    print("Placing item on pedestal at " .. textutils.serialize(position))
    updateStatus("working", "picking up item")
    
    -- Move above chest
    local chestAbovePos = {
        x = chestPos.x,
        y = chestPos.y + 1,
        z = chestPos.z
    }
    
    if not moveTo(chestAbovePos) then
        print("ERROR: Cannot move above chest")
        return false
    end
    
    -- Get item from chest
    local chest = peripheral.wrap("bottom")
    if not chest or not chest.list then
        print("ERROR: Cannot find chest below")
        return false
    end
    
    local itemSlot = nil
    for slot, chestItem in pairs(chest.list()) do
        if chestItem.name == item.item.name then
            local match = true
            if item.matchDMG and (chestItem.damage or 0) ~= (item.item.damage or 0) then
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
    
    if not turtle.suckDown(1) then
        print("ERROR: Cannot suck item from chest")
        return false
    end
    
    print("Picked up item from chest")
    updateStatus("working", "placing on pedestal")
    
    -- Move to pedestal
    local pedestalAbovePos = {
        x = position.x,
        y = position.y + 1,
        z = position.z
    }
    
    if not moveTo(pedestalAbovePos) then
        print("ERROR: Cannot move to pedestal")
        return false
    end
    
    if not turtle.dropDown(1) then
        print("ERROR: Cannot drop item onto pedestal")
        return false
    end
    
    print("Item placed on pedestal!")
    return true
end

-- Retrieve item from pedestal
local function retrieveItemFromPedestal(position, mePos)
    print("Retrieving item from pedestal at " .. textutils.serialize(position))
    updateStatus("working", "picking up result")
    
    local pedestalAbovePos = {
        x = position.x,
        y = position.y + 1,
        z = position.z
    }
    
    if not moveTo(pedestalAbovePos) then
        print("ERROR: Cannot move to pedestal")
        return false
    end
    
    if not turtle.suckDown(1) then
        print("ERROR: Cannot suck item from pedestal")
        return false
    end
    
    print("Picked up result item")
    updateStatus("working", "depositing to ME")
    
    local meAbovePos = {
        x = mePos.x,
        y = mePos.y + 1,
        z = mePos.z
    }
    
    if not moveTo(meAbovePos) then
        print("ERROR: Cannot move to ME Interface")
        return false
    end
    
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
        updateStatus("working", "placing catalyst")
        return placeItemOnPedestal(task.item, task.position, task.chestPosition)
        
    elseif task.type == "place_ingredient" then
        updateStatus("working", "placing ingredient")
        return placeItemOnPedestal(task.item, task.position, task.chestPosition)
        
    elseif task.type == "retrieve_result" then
        updateStatus("working", "retrieving result")
        return retrieveItemFromPedestal(task.position, task.meInterfacePosition)
    end
    
    return false
end

-- Process tasks
local function processTasks()
    while #tasks > 0 do
        local task = table.remove(tasks, 1)
        
        local success = executeTask(task)
        
        modem.transmit(CHANNEL, CHANNEL, {
            type = "turtle_task_complete",
            data = {
                turtleId = assignedId,
                success = success
            }
        })
    end
    
    returnHome()
end

-- Handle messages
local function handleMessage(msg)
    if type(msg) ~= "table" or not msg.type then return end
    
    if msg.type == "turtle_id_assigned" then
        if msg.data.computerId == turtleId then
            assignedId = msg.data.assignedId
            chestPosition = msg.data.chestPosition
            meInterfacePosition = msg.data.meInterfacePosition
            
            print("")
            print("=================================")
            print("Assigned ID: #" .. assignedId)
            print("=================================")
            print("")
            
            -- Start altar discovery
            scanForAltars()
        end
        
    elseif msg.type == "turtle_tasks" then
        if msg.data.turtleId == assignedId then
            tasks = msg.data.tasks
            processTasks()
        end
        
    elseif msg.type == "disaster_abort" then
        print("DISASTER ABORT! Stopping all tasks!")
        tasks = {}
        updateStatus("idle", "aborted")
        returnHome()
    end
end

-- Main loop
local function main()
    print("=================================")
    print("Thaumcraft Turtle Worker v2.0")
    print("=================================")
    
    turtleId = os.getComputerID()
    print("Computer ID: " .. turtleId)
    
    -- Get home position
    homePosition = getPosition()
    if not homePosition then
        error("ERROR: Cannot get GPS position! Make sure GPS is set up.")
    end
    
    print("Home position: " .. textutils.serialize(homePosition))
    
    -- Register with server
    modem.transmit(CHANNEL, CHANNEL, {
        type = "turtle_register",
        data = {
            position = homePosition,
            isGloveTurtle = false
        }
    })
    
    print("Registered with server")
    print("Waiting for ID assignment...")
    
    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent("modem_message")
        
        if channel == CHANNEL then
            handleMessage(message)
        end
    end
end

main()
