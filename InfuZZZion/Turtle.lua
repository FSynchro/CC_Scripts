-- Thaumcraft Infusion Turtle Worker v3.0
-- Handles item placement, retrieval, pedestal scanning

local CHANNEL = 1742

-- State
local modem = peripheral.find("modem")
local homePosition = nil
local currentPosition = nil
local lastGPSCheck = 0
local GPS_CHECK_INTERVAL = 10
local tasks = {}
local turtleId = nil
local assignedId = nil
local chestPosition = nil
local meInterfacePosition = nil

if not modem then
    error("No wireless modem found! Please attach an ender modem.")
end

modem.open(CHANNEL)

-- GPS position with caching
local function getPosition(forceGPS)
    local now = os.epoch("utc") / 1000
    
    if forceGPS or not currentPosition or (now - lastGPSCheck) >= GPS_CHECK_INTERVAL then
        local x, y, z = gps.locate(5)
        if x then
            currentPosition = {
                x = math.floor(x),
                y = math.floor(y),
                z = math.floor(z)
            }
            lastGPSCheck = now
            return currentPosition
        else
            if currentPosition then
                print("WARNING: GPS failed, using cached position")
                return currentPosition
            end
            return nil
        end
    end
    
    return currentPosition
end

-- Update position after movement
local function updatePositionAfterMove(dx, dy, dz)
    if currentPosition then
        currentPosition.x = currentPosition.x + dx
        currentPosition.y = currentPosition.y + dy
        currentPosition.z = currentPosition.z + dz
    end
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
    if turtle.getFuelLevel() < MIN_FUEL then
        for i = 1, 16 do
            turtle.select(i)
            if turtle.refuel(0) then
                turtle.refuel()
                print("Refueled! Current level: " .. turtle.getFuelLevel())
            end
        end
    end
    
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

-- Movement with fuel check and position tracking
-- Improved to travel at safer Y levels
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
    
    -- Determine safe travel height
    -- If going to chest area, approach horizontally first, then descend
    -- Otherwise, travel at catalyst Y + 2 to avoid hitting computers
    local safeY = target.y + 2
    local isChestDestination = chestPosition and 
                                math.abs(target.x - chestPosition.x) <= 1 and
                                math.abs(target.z - chestPosition.z) <= 1
    
    -- Direction alignment helper
    local function align(axis, targetCoord)
        local attempts = 0
        while attempts < 4 do
            if turtle.forward() then
                local moved = false
                if axis == "x" then
                    if targetCoord > current.x then
                        updatePositionAfterMove(1, 0, 0)
                        current.x = current.x + 1
                        moved = true
                    elseif targetCoord < current.x then
                        updatePositionAfterMove(-1, 0, 0)
                        current.x = current.x - 1
                        moved = true
                    end
                elseif axis == "z" then
                    if targetCoord > current.z then
                        updatePositionAfterMove(0, 0, 1)
                        current.z = current.z + 1
                        moved = true
                    elseif targetCoord < current.z then
                        updatePositionAfterMove(0, 0, -1)
                        current.z = current.z - 1
                        moved = true
                    end
                end
                
                if moved then
                    turtle.back()
                    if axis == "x" then
                        updatePositionAfterMove(current.x > target.x and 1 or -1, 0, 0)
                        current.x = current.x + (current.x > target.x and 1 or -1)
                    else
                        updatePositionAfterMove(0, 0, current.z > target.z and 1 or -1)
                        current.z = current.z + (current.z > target.z and 1 or -1)
                    end
                    return true
                end
            else
                turtle.dig()
            end
            
            turtle.turnRight()
            attempts = attempts + 1
        end
        return false
    end
    
    -- Step 1: Rise to safe travel height if needed
    if isChestDestination then
        -- For chest, stay at current Y until we're close
        local distToChest = math.abs(current.x - target.x) + math.abs(current.z - target.z)
        if distToChest > 2 then
            -- Travel at safe Y until close
            while current.y < safeY do
                if not turtle.up() then
                    turtle.digUp()
                    if not turtle.up() then break end
                end
                updatePositionAfterMove(0, 1, 0)
                current.y = current.y + 1
            end
        end
    else
        -- For altars/pedestals, always travel at safe Y
        while current.y < safeY do
            if not turtle.up() then
                turtle.digUp()
                if not turtle.up() then break end
            end
            updatePositionAfterMove(0, 1, 0)
            current.y = current.y + 1
        end
    end
    
    -- Step 2: Move X
    if current.x ~= target.x then
        align("x", target.x)
        while current.x ~= target.x do
            if not turtle.forward() then
                turtle.dig()
                if not turtle.forward() then break end
            end
            updatePositionAfterMove(current.x < target.x and 1 or -1, 0, 0)
            current.x = current.x + (current.x < target.x and 1 or -1)
        end
    end
    
    -- Step 3: Move Z
    if current.z ~= target.z then
        align("z", target.z)
        while current.z ~= target.z do
            if not turtle.forward() then
                turtle.dig()
                if not turtle.forward() then break end
            end
            updatePositionAfterMove(0, 0, current.z < target.z and 1 or -1)
            current.z = current.z + (current.z < target.z and 1 or -1)
        end
    end
    
    -- Step 4: Move Y to target
    while current.y > target.y do
        if not turtle.down() then
            turtle.digDown()
            if not turtle.down() then break end
        end
        updatePositionAfterMove(0, -1, 0)
        current.y = current.y - 1
    end
    
    while current.y < target.y do
        if not turtle.up() then
            turtle.digUp()
            if not turtle.up() then break end
        end
        updatePositionAfterMove(0, 1, 0)
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
    end
end

-- Scan for pedestals around catalyst
local function scanPedestalsAroundCatalyst(catalystPos)
    print("Scanning for pedestals around catalyst at " .. textutils.serialize(catalystPos))
    updateStatus("scanning", "scanning pedestals")
    
    local pedestals = {}
    
    -- Check positions around the catalyst (5x5 grid, excluding catalyst position)
    local offsets = {
        {x = -2, z = 0}, {x = 2, z = 0},   -- Front/back
        {x = 0, z = -2}, {x = 0, z = 2},   -- Left/right
        {x = -2, z = -2}, {x = -2, z = 2}, -- Corners
        {x = 2, z = -2}, {x = 2, z = 2},
        -- Also check the diagonals at distance 1
        {x = -1, z = -1}, {x = -1, z = 1},
        {x = 1, z = -1}, {x = 1, z = 1}
    }
    
    for _, offset in ipairs(offsets) do
        local checkPos = {
            x = catalystPos.x + offset.x,
            y = catalystPos.y,
            z = catalystPos.z + offset.z
        }
        
        -- Move above position
        local abovePos = {
            x = checkPos.x,
            y = checkPos.y + 1,
            z = checkPos.z
        }
        
        if moveTo(abovePos) then
            -- Check if there's a pedestal below
            local success, block = turtle.inspectDown()
            
            if success and block.name and block.name:find("edestal") then
                print("Found pedestal at " .. textutils.serialize(checkPos))
                table.insert(pedestals, checkPos)
            end
        end
    end
    
    returnHome()
    
    print("Scan complete! Found " .. #pedestals .. " pedestals")
    return pedestals
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

-- Clear pedestal (retrieve leftover ingredient)
local function clearPedestal(position, mePos)
    print("Clearing pedestal at " .. textutils.serialize(position))
    updateStatus("working", "clearing pedestal")
    
    local pedestalAbovePos = {
        x = position.x,
        y = position.y + 1,
        z = position.z
    }
    
    if not moveTo(pedestalAbovePos) then
        print("ERROR: Cannot move to pedestal")
        return false
    end
    
    -- Try to suck item
    if turtle.suckDown(1) then
        print("Picked up item from pedestal")
        
        -- Deposit to ME
        local meAbovePos = {
            x = mePos.x,
            y = mePos.y + 1,
            z = mePos.z
        }
        
        if moveTo(meAbovePos) then
            turtle.dropDown(1)
            print("Item deposited into ME Interface")
        end
    else
        print("No item on pedestal (already cleared)")
    end
    
    return true
end

-- Execute task
local function executeTask(task)
    print("Executing task: " .. task.type)
    
    if task.type == "scan_pedestals" then
        updateStatus("scanning", "scanning pedestals")
        local pedestals = scanPedestalsAroundCatalyst(task.catalystPosition)
        
        -- Report results to server
        modem.transmit(CHANNEL, CHANNEL, {
            type = "pedestals_scanned",
            data = {
                altarId = task.altarId,
                pedestalPositions = pedestals
            }
        })
        return true
        
    elseif task.type == "place_catalyst" then
        updateStatus("working", "placing catalyst")
        return placeItemOnPedestal(task.item, task.position, task.chestPosition)
        
    elseif task.type == "place_ingredient" then
        updateStatus("working", "placing ingredient")
        return placeItemOnPedestal(task.item, task.position, task.chestPosition)
        
    elseif task.type == "retrieve_result" then
        updateStatus("working", "retrieving result")
        return retrieveItemFromPedestal(task.position, task.meInterfacePosition)
        
    elseif task.type == "clear_pedestal" then
        updateStatus("working", "clearing pedestal")
        return clearPedestal(task.position, task.meInterfacePosition)
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
            print("Ready for tasks...")
        end
    
    elseif msg.type == "scan_pedestals" then
        -- Server wants us to scan pedestals
        tasks = {{
            type = "scan_pedestals",
            altarId = msg.data.altarId,
            catalystPosition = msg.data.catalystPosition
        }}
        processTasks()
        
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
    print("Thaumcraft Turtle Worker v3.0")
    print("=================================")
    
    turtleId = os.getComputerID()
    print("Computer ID: " .. turtleId)
    
    -- Get home position (force GPS)
    homePosition = getPosition(true)
    if not homePosition then
        error("ERROR: Cannot get GPS position! Make sure GPS is set up.")
    end
    
    print("Home position: " .. textutils.serialize(homePosition))
    print("GPS check interval: " .. GPS_CHECK_INTERVAL .. " seconds")
    
    -- Register with server
    modem.transmit(CHANNEL, CHANNEL, {
        type = "turtle_register",
        data = {
            position = homePosition
        }
    })
    
    print("Registered with server")
    print("Waiting for ID assignment...")
    
    -- Start timers
    local registerTimer = os.startTimer(5)
    local keepaliveTimer = os.startTimer(10)
    
    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent()
        
        if event == "modem_message" and channel == CHANNEL then
            handleMessage(message)
            
        elseif event == "timer" then
            if side == registerTimer then
                -- Re-register if we don't have an ID yet
                if not assignedId then
                    print("Retrying registration...")
                    modem.transmit(CHANNEL, CHANNEL, {
                        type = "turtle_register",
                        data = {
                            position = homePosition
                        }
                    })
                end
                registerTimer = os.startTimer(5)
                
            elseif side == keepaliveTimer then
                -- Send keepalive to server
                if assignedId then
                    modem.transmit(CHANNEL, CHANNEL, {
                        type = "turtle_keepalive",
                        data = {
                            turtleId = assignedId,
                            position = currentPosition or homePosition
                        }
                    })
                end
                keepaliveTimer = os.startTimer(10)
            end
        end
    end
end

main()
