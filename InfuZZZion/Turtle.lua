-- Thaumcraft Infusion Turtle Worker v3.0
-- Handles item placement, retrieval, pedestal scanning

local CHANNEL = 1742
local ID_FILE = "turtle_id.dat"

-- State
local modem = peripheral.find("modem")
local homePosition = nil
local currentPosition = nil
local lastGPSCheck = 0
local GPS_CHECK_INTERVAL = 10
local tasks = {}
local computerID = os.getComputerID()  -- Get actual computer ID
local assignedId = nil
local chestPosition = nil
local meInterfacePosition = nil

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
            facing = data.facing or 0  -- Load facing direction
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
        facing = facing  -- Save facing direction
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

-- Turtle facing direction (0=North/Z-, 1=East/X+, 2=South/Z+, 3=West/X-)
local facing = 0

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
        -- Need to go East (+X) = facing 1
        turnToFace(1)
        if not turtle.forward() then
            turtle.dig()
            if not turtle.forward() then break end
        end
        updatePositionAfterMove(1, 0, 0)
        current.x = current.x + 1
    end
    
    while current.x > target.x do
        -- Need to go West (-X) = facing 3
        turnToFace(3)
        if not turtle.forward() then
            turtle.dig()
            if not turtle.forward() then break end
        end
        updatePositionAfterMove(-1, 0, 0)
        current.x = current.x - 1
    end
    
    -- Move Z (South/North)
    while current.z < target.z do
        -- Need to go South (+Z) = facing 2
        turnToFace(2)
        if not turtle.forward() then
            turtle.dig()
            if not turtle.forward() then break end
        end
        updatePositionAfterMove(0, 0, 1)
        current.z = current.z + 1
    end
    
    while current.z > target.z do
        -- Need to go North (-Z) = facing 0
        turnToFace(0)
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
        saveId()  -- Save position and facing after returning home
        updateStatus("idle", "waiting")
    end
end

-- Scan for pedestals around catalyst (7x7 area, 1 block above pedestals)
local function scanPedestalsAroundCatalyst(catalystPos)
    print("Scanning 7x7 area around catalyst at " .. textutils.serialize(catalystPos))
    print("Current fuel level: " .. turtle.getFuelLevel())
    updateStatus("scanning", "scanning pedestals")
    
    local pedestals = {}
    
    -- Pedestals are at catalystPos.y + 1 (one above the computer)
    -- We fly at catalystPos.y + 2 (one above the pedestals, so we can inspectDown)
    local flyingY = catalystPos.y + 2
    
    print("Flying at Y=" .. flyingY .. " (1 block above pedestals)")
    
    -- Scan 7x7 grid centered on catalyst (-3 to +3 in X and Z)
    for xOffset = -3, 3 do
        for zOffset = -3, 3 do
            -- Skip center (that's the catalyst pedestal)
            if not (xOffset == 0 and zOffset == 0) then
                local scanPos = {
                    x = catalystPos.x + xOffset,
                    y = flyingY,
                    z = catalystPos.z + zOffset
                }
                
                -- Move to scan position
                if moveTo(scanPos) then
                    -- Check what's below us
                    local success, block = turtle.inspectDown()
                    
                    if success and block.name then
                        -- Check if it's a pedestal
                        if block.name:find("edestal") then
                            print("Found pedestal: " .. block.name)
                            
                            -- Get exact GPS position
                            local gpsPos = getPosition(true)
                            
                            -- Pedestal is 1 block below us
                            local pedestalPos = {
                                x = gpsPos.x,
                                y = gpsPos.y - 1,
                                z = gpsPos.z
                            }
                            
                            print("Pedestal GPS: " .. textutils.serialize(pedestalPos))
                            table.insert(pedestals, pedestalPos)
                        end
                    end
                else
                    print("WARNING: Could not reach scan position " .. textutils.serialize(scanPos))
                end
            end
        end
    end
    
    -- Sort pedestals: center first, then corners
    -- Distance from catalyst determines order
    table.sort(pedestals, function(a, b)
        local distA = math.abs(a.x - catalystPos.x) + math.abs(a.z - catalystPos.z)
        local distB = math.abs(b.x - catalystPos.x) + math.abs(b.z - catalystPos.z)
        return distA < distB
    end)
    
    print("Scan complete! Found " .. #pedestals .. " pedestals")
    print("Sorted by distance: center first, corners last")
    
    returnHome()
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
    
    -- Move to pedestal (position + 1 to be above it)
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
        if msg.data.computerId == computerID then
            assignedId = msg.data.assignedId
            chestPosition = msg.data.chestPosition
            meInterfacePosition = msg.data.meInterfacePosition
            
            -- Save the assigned ID
            saveId()
            
            print("")
            print("=================================")
            print("Assigned ID: #" .. assignedId)
            print("=================================")
            print("")
            print("Ready for tasks...")
        end
    
    elseif msg.type == "scan_pedestals" then
        -- Server wants us to scan pedestals (check if it's for this turtle)
        if msg.data.turtleId == assignedId then
            print("Received scan task for altar #" .. msg.data.altarId)
            tasks = {{
                type = "scan_pedestals",
                altarId = msg.data.altarId,
                catalystPosition = msg.data.catalystPosition
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
    print("Thaumcraft Turtle Worker v3.0")
    print("=================================")
    
    print("Computer ID: " .. computerID)
    print("Fuel level: " .. turtle.getFuelLevel())
    
    if turtle.getFuelLevel() < 100 then
        print("WARNING: Low fuel! Please add coal/charcoal to turtle inventory.")
    end
    
    -- Try to load saved ID
    local hasSavedId = loadSavedId()
    
    -- Get home position (force GPS)
    homePosition = getPosition(true)
    if not homePosition then
        error("ERROR: Cannot get GPS position! Make sure GPS is set up.")
    end
    
    print("Home position: " .. textutils.serialize(homePosition))
    print("GPS check interval: " .. GPS_CHECK_INTERVAL .. " seconds")
    
    -- Register with server (or re-register if we have saved ID)
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
    
    -- Start timers
    local registerTimer = os.startTimer(5)
    local keepaliveTimer = os.startTimer(10)
    
    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent()
        
        if event == "modem_message" and channel == CHANNEL then
            handleMessage(message)
            
        elseif event == "timer" then
            if side == registerTimer then
                -- Only retry registration if we DON'T have an ID yet
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
                    -- We have an ID, just send keepalive
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
