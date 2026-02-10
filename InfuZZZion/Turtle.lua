-- Thaumcraft Infusion Turtle Worker v2.0
-- Handles item placement, retrieval, and altar discovery

local CHANNEL = 1742
local PEDESTAL_BLOCK = "Thaumcraft:blockPedestal" -- Adjust based on actual block ID

-- State
local modem = peripheral.find("modem")
local homePosition = nil
local currentPosition = nil -- Track position without GPS
local lastGPSCheck = 0
local GPS_CHECK_INTERVAL = 10 -- Seconds between GPS confirmations
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
    
    -- Force GPS check or periodic check
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
            -- GPS failed, return cached position if available
            if currentPosition then
                print("WARNING: GPS failed, using cached position")
                return currentPosition
            end
            return nil
        end
    end
    
    -- Return cached position
    return currentPosition
end

-- Update position after movement (no GPS needed)
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

-- Movement with fuel check and position tracking
local function moveTo(target, bypassFuel)
    if not bypassFuel and not checkFuel() then
        print("STALLED: Waiting for fuel...")
        return false
    end
    
    local current = getPosition() -- Only uses GPS if needed
    if not current then return false end
    
    if turtle.getFuelLevel() < 10 then
        print("ERROR: Out of fuel!")
        return false
    end
    
    -- Direction alignment helper
    local function align(axis, targetCoord)
        local attempts = 0
        while attempts < 4 do
            -- Test forward movement
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
                    -- We're facing the right direction
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
    
    -- Move X
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
    
    -- Move Z
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
    
    -- Move Y
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
        
        modem.transmit(CHANNEL, CHANNEL, {
            type = "turtle_returned",
            data = {
                turtleId = assignedId
            }
        })
    end
end

-- Verify potential altar blocks during setup cycle
local function verifyAltarBlocks(blocksToCheck)
    print("Verifying " .. #blocksToCheck .. " potential altar blocks...")
    updateStatus("scanning", "verifying altar blocks")
    
    local confirmedAltars = {}
    
    for _, block in ipairs(blocksToCheck) do
        -- Move to position above block
        local checkPos = {
            x = block.x,
            y = block.y + 1,
            z = block.z
        }
        
        if moveTo(checkPos) then
            -- Check if there's a pedestal above this block
            local success, inspectedBlock = turtle.inspectUp()
            
            if success and inspectedBlock.name and inspectedBlock.name:find("edestal") then
                print("Confirmed altar catalyst at " .. textutils.serialize(block))
                
                -- This is a catalyst pedestal, find surrounding pedestals
                local pedestals = findSurroundingPedestals(block)
                
                if #pedestals >= 4 then
                    table.insert(confirmedAltars, {
                        catalyst = block,
                        pedestals = pedestals
                    })
                    
                    -- Report to server
                    modem.transmit(CHANNEL, CHANNEL, {
                        type = "altar_found",
                        data = {
                            catalystPos = block,
                            pedestalPositions = pedestals,
                            turtleId = assignedId
                        }
                    })
                end
            end
        end
    end
    
    returnHome()
    
    print("Verification complete! Found " .. #confirmedAltars .. " altars")
    
    -- Notify server we're done
    modem.transmit(CHANNEL, CHANNEL, {
        type = "setup_verification_complete",
        data = {
            turtleId = assignedId,
            foundAltars = #confirmedAltars
        }
    })
    
    updateStatus("idle", "waiting")
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
            print("Waiting for setup cycle to begin...")
        end
    
    elseif msg.type == "setup_verify_blocks" then
        if msg.data.turtleId == assignedId then
            verifyAltarBlocks(msg.data.blocks)
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
