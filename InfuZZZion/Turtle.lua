-- Thaumcraft Infusion Turtle Worker v3.1
-- FIXED: Now detects stabilizers (heads/candles/skulls) in addition to pedestals

local CHANNEL = 1742
local ID_FILE = "turtle_id.dat"

-- State
local modem = peripheral.find("modem")
local homePosition = nil
local currentPosition = nil
local lastGPSCheck = 0
local GPS_CHECK_INTERVAL = 10
local tasks = {}
local computerID = os.getComputerID()
local assignedId = nil
local chestPosition = nil
local meInterfacePosition = nil
local facing = 0 -- Direction turtle is facing

if not modem then
    error("No wireless modem found! Please attach an ender modem.")
end

modem.open(CHANNEL)

-- Load saved ID if exists
local function loadSavedId()
    if fs.exists(ID_FILE) then
        local file = fs.open(ID_FILE, "r")
        local data = textutils.unserialize(file.readAll())
        file.close()
        
        if data and data.assignedId then
            assignedId = data.assignedId
            facing = data.facing or 0
            print("Loaded saved turtle ID: #" .. assignedId)
            print("Loaded facing direction: " .. facing)
            return true
        end
    end
    return false
end

-- Save assigned ID
local function saveId()
    local file = fs.open(ID_FILE, "w")
    file.write(textutils.serialize({
        assignedId = assignedId,
        computerID = computerID,
        facing = facing
    }))
    file.close()
end

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

-- Turn turtle to face a specific direction
local function turnToFace(targetFacing)
    while facing ~= targetFacing do
        turtle.turnRight()
        facing = (facing + 1) % 4
    end
end

-- Movement with fuel check and position tracking
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
    
    -- Move to target Y first
    while current.y < target.y do
        if not turtle.up() then
            turtle.digUp()
            if not turtle.up() then break end
        end
        updatePositionAfterMove(0, 1, 0)
        current.y = current.y + 1
    end
    
    -- Move X (East/West)
    while current.x < target.x do
        turnToFace(1) -- East
        if not turtle.forward() then
            turtle.dig()
            if not turtle.forward() then break end
        end
        updatePositionAfterMove(1, 0, 0)
        current.x = current.x + 1
    end
    
    while current.x > target.x do
        turnToFace(3) -- West
        if not turtle.forward() then
            turtle.dig()
            if not turtle.forward() then break end
        end
        updatePositionAfterMove(-1, 0, 0)
        current.x = current.x - 1
    end
    
    -- Move Z (South/North)
    while current.z < target.z do
        turnToFace(2) -- South
        if not turtle.forward() then
            turtle.dig()
            if not turtle.forward() then break end
        end
        updatePositionAfterMove(0, 0, 1)
        current.z = current.z + 1
    end
    
    while current.z > target.z do
        turnToFace(0) -- North
        if not turtle.forward() then
            turtle.dig()
            if not turtle.forward() then break end
        end
        updatePositionAfterMove(0, 0, -1)
        current.z = current.z - 1
    end
    
    -- Move Y down if needed
    while current.y > target.y do
        if not turtle.down() then
            turtle.digDown()
            if not turtle.down() then break end
        end
        updatePositionAfterMove(0, -1, 0)
        current.y = current.y - 1
    end
    
    return true
end

-- Return to home position
local function returnHome()
    if homePosition then
        print("Returning home...")
        updateStatus("returning", "going to home position")
        moveTo(homePosition)
        saveId()
        updateStatus("idle", "waiting")
    end
end

-- Check if block is a stabilizer (skull, candle, head)
local function isStabilizer(blockName)
    if not blockName then return false end
    local lowerName = blockName:lower()
    return lowerName:find("skull") or 
           lowerName:find("head") or 
           lowerName:find("candle")
end

-- Scan for pedestals AND stabilizers around catalyst
local function scanPedestalsAroundCatalyst(catalystPos, assignedRows)
    print("=== Starting Pedestal Scan ===")
    print("Catalyst position: " .. textutils.serialize(catalystPos))
    print("Assigned rows (Z offsets): " .. textutils.serialize(assignedRows))
    print("Current fuel level: " .. turtle.getFuelLevel())
    updateStatus("scanning", "scanning pedestals")
    
    local pedestals = {}
    local stabilizers = {}
    local foundPedestals = {}
    local foundStabilizers = {}
    
    -- Flying height: 2 blocks above catalyst pedestal (1 above catalyst computer)
    local flyingY = catalystPos.y + 2
    
    print("Flying at Y=" .. flyingY .. " (2 above catalyst)")
    
    -- Scan assigned rows only, northwest to southeast
    for _, zOffset in ipairs(assignedRows) do
        print("Scanning row Z offset: " .. zOffset)
        
        -- Scan west to east (X from -3 to +3)
        for xOffset = -3, 3 do
            -- Skip center (catalyst pedestal at zOffset=0, xOffset=0)
            if not (xOffset == 0 and zOffset == 0) then
                local scanPos = {
                    x = catalystPos.x + xOffset,
                    y = flyingY,
                    z = catalystPos.z + zOffset
                }
                
                -- Move to scan position
                if moveTo(scanPos) then
                    -- Verify Y level
                    local currentPos = getPosition(false)
                    if currentPos and currentPos.y ~= flyingY then
                        print("WARNING: Y drift! Correcting to " .. flyingY)
                        while currentPos.y < flyingY do
                            turtle.up()
                            currentPos = getPosition(false)
                        end
                        while currentPos.y > flyingY do
                            turtle.down()
                            currentPos = getPosition(false)
                        end
                    end
                    
                    -- Check what's below us
                    local success, block = turtle.inspectDown()
                    
                    if success and block.name then
                        local gpsPos = getPosition(true)
                        
                        -- Check if it's a pedestal
                        if block.name:find("edestal") then
                            local pedestalPos = {
                                x = gpsPos.x,
                                y = gpsPos.y - 1,  -- Pedestal is 1 block below
                                z = gpsPos.z
                            }
                            
                            local posKey = pedestalPos.x .. "," .. pedestalPos.y .. "," .. pedestalPos.z
                            
                            if not foundPedestals[posKey] then
                                foundPedestals[posKey] = true
                                print("Found PEDESTAL: " .. block.name .. " at " .. textutils.serialize(pedestalPos))
                                table.insert(pedestals, pedestalPos)
                            end
                        
                        -- Check if it's a stabilizer (skull, candle, head)
                        elseif isStabilizer(block.name) then
                            local stabilizerPos = {
                                x = gpsPos.x,
                                y = gpsPos.y - 1,  -- Stabilizer is 1 block below
                                z = gpsPos.z
                            }
                            
                            local posKey = stabilizerPos.x .. "," .. stabilizerPos.y .. "," .. stabilizerPos.z
                            
                            if not foundStabilizers[posKey] then
                                foundStabilizers[posKey] = true
                                print("Found STABILIZER: " .. block.name .. " at " .. textutils.serialize(stabilizerPos))
                                table.insert(stabilizers, stabilizerPos)
                            end
                        end
                    end
                else
                    print("WARNING: Could not reach scan position " .. textutils.serialize(scanPos))
                end
            end
        end
    end
    
    print("=== Scan Complete ===")
    print("Found " .. #pedestals .. " pedestals")
    print("Found " .. #stabilizers .. " stabilizers")
    
    returnHome()
    return pedestals, stabilizers
end

-- Place item on pedestal
local function placeItemOnPedestal(item, position, chestPos)
    print("Placing item on pedestal at " .. textutils.serialize(position))
    updateStatus("working", "picking up item")
    
    local chestAbovePos = {
        x = chestPos.x,
        y = chestPos.y + 1,
        z = chestPos.z
    }
    
    if not moveTo(chestAbovePos) then
        print("ERROR: Cannot move above chest")
        return false
    end
    
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

-- Clear pedestal
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
    
    if turtle.suckDown(1) then
        print("Picked up item from pedestal")
        
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
        local pedestals, stabilizers = scanPedestalsAroundCatalyst(task.catalystPosition, task.assignedRows)
        
        -- Report results to server
        modem.transmit(CHANNEL, CHANNEL, {
            type = "pedestals_scanned",
            data = {
                altarId = task.altarId,
                pedestalPositions = pedestals,
                stabilizerPositions = stabilizers,
                turtleId = assignedId
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
        if msg.data.computerId == computerID then
            assignedId = msg.data.assignedId
            chestPosition = msg.data.chestPosition
            meInterfacePosition = msg.data.meInterfacePosition
            
            saveId()
            
            print("")
            print("=================================")
            print("Assigned ID: #" .. assignedId)
            print("=================================")
            print("")
            print("Ready for tasks...")
        end
    
    elseif msg.type == "scan_pedestals" then
        if msg.data.turtleId == assignedId then
            print("Received scan task for altar #" .. msg.data.altarId)
            tasks = {{
                type = "scan_pedestals",
                altarId = msg.data.altarId,
                catalystPosition = msg.data.catalystPosition,
                assignedRows = msg.data.assignedRows
            }}
            processTasks()
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
    print("Thaumcraft Turtle Worker v3.1")
    print("=================================")
    
    print("Computer ID: " .. computerID)
    print("Fuel level: " .. turtle.getFuelLevel())
    
    if turtle.getFuelLevel() < 100 then
        print("WARNING: Low fuel! Please add coal/charcoal.")
    end
    
    local hasSavedId = loadSavedId()
    
    homePosition = getPosition(true)
    if not homePosition then
        error("ERROR: Cannot get GPS position!")
    end
    
    print("Home position: " .. textutils.serialize(homePosition))
    
    if hasSavedId then
        print("Re-registering with server using saved ID #" .. assignedId)
        modem.transmit(CHANNEL, CHANNEL, {
            type = "turtle_reregister",
            data = {
                turtleId = assignedId,
                computerId = computerID,
                position = homePosition
            }
        })
    else
        print("Registering with server as new turtle")
        modem.transmit(CHANNEL, CHANNEL, {
            type = "turtle_register",
            data = {
                computerId = computerID,
                position = homePosition
            }
        })
    end
    
    print("Waiting for confirmation...")
    
    local registerTimer = os.startTimer(5)
    local keepaliveTimer = os.startTimer(10)
    
    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent()
        
        if event == "modem_message" and channel == CHANNEL then
            handleMessage(message)
            
        elseif event == "timer" then
            if side == registerTimer then
                if not assignedId then
                    print("Retrying registration...")
                    modem.transmit(CHANNEL, CHANNEL, {
                        type = "turtle_register",
                        data = {
                            computerId = computerID,
                            position = homePosition
                        }
                    })
                else
                    modem.transmit(CHANNEL, CHANNEL, {
                        type = "turtle_keepalive",
                        data = {
                            turtleId = assignedId,
                            position = currentPosition or homePosition
                        }
                    })
                end
                registerTimer = os.startTimer(5)
                
            elseif side == keepaliveTimer then
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
