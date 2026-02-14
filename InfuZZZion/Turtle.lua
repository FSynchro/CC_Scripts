-- Thaumcraft Infusion Turtle Worker v3.2
-- REDESIGNED: Slow, methodical scanning with GPS verification

local CHANNEL = 1742
local ID_FILE = "turtle_id.dat"
local SCAN_DELAY = 0.5 -- Delay between each scan position (seconds)
local MOVE_DELAY = 0.3 -- Delay after each movement
local GPS_VERIFY_RETRIES = 3 -- Times to retry GPS at each position

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
local facing = 0

if not modem then
    error("No wireless modem found! Please attach an ender modem.")
end

modem.open(CHANNEL)

-- Load saved ID
local function loadSavedId()
    if fs.exists(ID_FILE) then
        local file = fs.open(ID_FILE, "r")
        local data = textutils.unserialize(file.readAll())
        file.close()
        
        if data and data.assignedId then
            assignedId = data.assignedId
            facing = data.facing or 0
            print("Loaded saved turtle ID: #" .. assignedId)
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

-- GPS position with retries
local function getPosition(forceGPS)
    local now = os.epoch("utc") / 1000
    
    if forceGPS or not currentPosition or (now - lastGPSCheck) >= GPS_CHECK_INTERVAL then
        -- Try multiple times
        for attempt = 1, GPS_VERIFY_RETRIES do
            local x, y, z = gps.locate(5)
            if x then
                currentPosition = {
                    x = math.floor(x),
                    y = math.floor(y),
                    z = math.floor(z)
                }
                lastGPSCheck = now
                return currentPosition
            end
            
            if attempt < GPS_VERIFY_RETRIES then
                print("GPS attempt " .. attempt .. " failed, retrying...")
                sleep(0.5)
            end
        end
        
        -- All attempts failed
        if currentPosition then
            print("WARNING: GPS failed after " .. GPS_VERIFY_RETRIES .. " attempts, using cached position")
            return currentPosition
        end
        return nil
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

-- Send status update
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

-- Send keepalive
local function sendKeepalive()
    if assignedId then
        modem.transmit(CHANNEL, CHANNEL, {
            type = "turtle_keepalive",
            data = {
                turtleId = assignedId,
                position = currentPosition or homePosition
            }
        })
    end
end

-- Fuel check
local MIN_FUEL = 200
local REFUEL_THRESHOLD = 50

local function checkFuel()
    if turtle.getFuelLevel() < REFUEL_THRESHOLD then
        print("CRITICAL FUEL: " .. turtle.getFuelLevel())
        return false
    end
    return true
end

-- Turn to face direction
local function turnToFace(targetFacing)
    while facing ~= targetFacing do
        turtle.turnRight()
        facing = (facing + 1) % 4
        sleep(MOVE_DELAY)
    end
end

-- Safe movement with verification
local function moveForward()
    if not turtle.forward() then
        turtle.dig()
        sleep(0.2)
        if not turtle.forward() then
            return false
        end
    end
    sleep(MOVE_DELAY)
    return true
end

local function moveUp()
    if not turtle.up() then
        turtle.digUp()
        sleep(0.2)
        if not turtle.up() then
            return false
        end
    end
    sleep(MOVE_DELAY)
    return true
end

local function moveDown()
    if not turtle.down() then
        turtle.digDown()
        sleep(0.2)
        if not turtle.down() then
            return false
        end
    end
    sleep(MOVE_DELAY)
    return true
end

-- Move to target position SLOWLY with GPS-based position tracking
local function moveTo(target)
    if not checkFuel() then
        print("ERROR: Low fuel!")
        return false
    end
    
    local startPos = getPosition(true)
    if not startPos then 
        print("ERROR: Cannot get GPS position!")
        return false 
    end
    
    print("Moving from " .. textutils.serialize(startPos))
    print("         to " .. textutils.serialize(target))
    
    local MAX_AXIS_ATTEMPTS = 5  -- Max attempts per axis before giving up
    local stuckCounter = 0
    
    -- Move Y first
    local yAttempts = 0
    while yAttempts < MAX_AXIS_ATTEMPTS do
        local current = getPosition(true)  -- Get fresh GPS position
        if not current then
            print("ERROR: Lost GPS signal!")
            return false
        end
        
        if current.y == target.y then
            break  -- Y is correct
        elseif current.y < target.y then
            print("  Moving UP (y=" .. current.y .. " -> " .. target.y .. ")")
            if moveUp() then
                stuckCounter = 0  -- Reset stuck counter on success
            else
                print("  UP BLOCKED!")
                yAttempts = yAttempts + 1
                stuckCounter = stuckCounter + 1
                if stuckCounter >= 3 then
                    print("ERROR: Stuck! Cannot move in any direction!")
                    return false
                end
            end
            sendKeepalive()
        elseif current.y > target.y then
            print("  Moving DOWN (y=" .. current.y .. " -> " .. target.y .. ")")
            if moveDown() then
                stuckCounter = 0
            else
                print("  DOWN BLOCKED!")
                yAttempts = yAttempts + 1
                stuckCounter = stuckCounter + 1
                if stuckCounter >= 3 then
                    print("ERROR: Stuck! Cannot move in any direction!")
                    return false
                end
            end
            sendKeepalive()
        end
    end
    
    if yAttempts >= MAX_AXIS_ATTEMPTS then
        print("ERROR: Cannot reach target Y after " .. MAX_AXIS_ATTEMPTS .. " attempts")
        return false
    end
    
    -- Move X
    local xAttempts = 0
    while xAttempts < MAX_AXIS_ATTEMPTS do
        local current = getPosition(true)
        if not current then
            print("ERROR: Lost GPS signal!")
            return false
        end
        
        if current.x == target.x then
            break  -- X is correct
        elseif current.x < target.x then
            print("  Moving EAST (x=" .. current.x .. " -> " .. target.x .. ")")
            turnToFace(1)
            if moveForward() then
                stuckCounter = 0
            else
                print("  EAST BLOCKED!")
                xAttempts = xAttempts + 1
                stuckCounter = stuckCounter + 1
                if stuckCounter >= 3 then
                    print("ERROR: Stuck! Cannot move in any direction!")
                    return false
                end
            end
            sendKeepalive()
        elseif current.x > target.x then
            print("  Moving WEST (x=" .. current.x .. " -> " .. target.x .. ")")
            turnToFace(3)
            if moveForward() then
                stuckCounter = 0
            else
                print("  WEST BLOCKED!")
                xAttempts = xAttempts + 1
                stuckCounter = stuckCounter + 1
                if stuckCounter >= 3 then
                    print("ERROR: Stuck! Cannot move in any direction!")
                    return false
                end
            end
            sendKeepalive()
        end
    end
    
    if xAttempts >= MAX_AXIS_ATTEMPTS then
        print("ERROR: Cannot reach target X after " .. MAX_AXIS_ATTEMPTS .. " attempts")
        return false
    end
    
    -- Move Z
    local zAttempts = 0
    while zAttempts < MAX_AXIS_ATTEMPTS do
        local current = getPosition(true)
        if not current then
            print("ERROR: Lost GPS signal!")
            return false
        end
        
        if current.z == target.z then
            break  -- Z is correct
        elseif current.z < target.z then
            print("  Moving SOUTH (z=" .. current.z .. " -> " .. target.z .. ")")
            turnToFace(2)
            if moveForward() then
                stuckCounter = 0
            else
                print("  SOUTH BLOCKED!")
                zAttempts = zAttempts + 1
                stuckCounter = stuckCounter + 1
                if stuckCounter >= 3 then
                    print("ERROR: Stuck! Cannot move in any direction!")
                    return false
                end
            end
            sendKeepalive()
        elseif current.z > target.z then
            print("  Moving NORTH (z=" .. current.z .. " -> " .. target.z .. ")")
            turnToFace(0)
            if moveForward() then
                stuckCounter = 0
            else
                print("  NORTH BLOCKED!")
                zAttempts = zAttempts + 1
                stuckCounter = stuckCounter + 1
                if stuckCounter >= 3 then
                    print("ERROR: Stuck! Cannot move in any direction!")
                    return false
                end
            end
            sendKeepalive()
        end
    end
    
    if zAttempts >= MAX_AXIS_ATTEMPTS then
        print("ERROR: Cannot reach target Z after " .. MAX_AXIS_ATTEMPTS .. " attempts")
        return false
    end
    
    -- Final verification
    local finalPos = getPosition(true)
    if finalPos then
        currentPosition = finalPos  -- Update cached position
        
        if finalPos.x == target.x and finalPos.y == target.y and finalPos.z == target.z then
            print("  Arrived successfully!")
            return true
        else
            print("ERROR: Position mismatch after movement!")
            print("  Expected: " .. textutils.serialize(target))
            print("  Actual:   " .. textutils.serialize(finalPos))
            return false
        end
    end
    
    print("ERROR: GPS verification failed!")
    return false
end

-- Return home
local function returnHome()
    if homePosition then
        print("=== Returning home ===")
        updateStatus("returning", "going to home position")
        if moveTo(homePosition) then
            print("=== Home! ===")
            saveId()
            updateStatus("idle", "waiting")
            return true
        else
            print("ERROR: Could not return home!")
            return false
        end
    end
    return false
end

-- Check if block is stabilizer
local function isStabilizer(blockName)
    if not blockName then return false end
    local lowerName = blockName:lower()
    return lowerName:find("skull") or 
           lowerName:find("head") or 
           lowerName:find("candle")
end

-- REDESIGNED: Slow, methodical scanning
local function scanPedestalsAroundCatalyst(catalystPos, assignedRows)
    print("=================================")
    print("STARTING PEDESTAL SCAN")
    print("=================================")
    print("Catalyst position: " .. textutils.serialize(catalystPos))
    print("Assigned rows (Z): " .. textutils.serialize(assignedRows))
    print("Fuel: " .. turtle.getFuelLevel())
    print("=================================")
    
    updateStatus("scanning", "scanning pedestals")
    sendKeepalive()
    
    local pedestals = {}
    local stabilizers = {}
    local foundPedestals = {}
    local foundStabilizers = {}
    
    -- Fly at Y+2 (2 blocks above catalyst)
    local flyingY = catalystPos.y + 2
    
    print("Flying at Y=" .. flyingY .. " (2 above catalyst)")
    
    -- Scan each assigned row SLOWLY
    local totalFailed = 0
    local MAX_TOTAL_FAILURES = 10  -- Abort if too many positions fail
    
    for rowIdx, zOffset in ipairs(assignedRows) do
        print("")
        print("--- ROW " .. rowIdx .. "/" .. #assignedRows .. " (Z offset: " .. zOffset .. ") ---")
        
        -- Scan west to east (X from -3 to +3)
        for xOffset = -3, 3 do
            -- Skip center (catalyst)
            if not (xOffset == 0 and zOffset == 0) then
                local scanPos = {
                    x = catalystPos.x + xOffset,
                    y = flyingY,
                    z = catalystPos.z + zOffset
                }
                
                print("")
                print("Scan position [" .. xOffset .. "," .. zOffset .. "]")
                
                -- Move to position
                if moveTo(scanPos) then
                    -- VERIFY we're at the right position
                    local verifyPos = getPosition(true)
                    if verifyPos and 
                       verifyPos.x == scanPos.x and 
                       verifyPos.y == scanPos.y and 
                       verifyPos.z == scanPos.z then
                        
                        -- Wait before scanning
                        sleep(SCAN_DELAY)
                        
                        -- Scan what's below
                        local success, block = turtle.inspectDown()
                        
                        if success and block.name then
                            print("  Detected: " .. block.name)
                            
                            local itemPos = {
                                x = verifyPos.x,
                                y = verifyPos.y - 1,
                                z = verifyPos.z
                            }
                            
                            local posKey = itemPos.x .. "," .. itemPos.y .. "," .. itemPos.z
                            
                            -- Check for pedestal
                            if block.name:find("edestal") then
                                if not foundPedestals[posKey] then
                                    foundPedestals[posKey] = true
                                    table.insert(pedestals, itemPos)
                                    print("  >>> PEDESTAL FOUND <<<")
                                end
                            
                            -- Check for stabilizer
                            elseif isStabilizer(block.name) then
                                if not foundStabilizers[posKey] then
                                    foundStabilizers[posKey] = true
                                    table.insert(stabilizers, itemPos)
                                    print("  >>> STABILIZER FOUND <<<")
                                end
                            else
                                print("  (other block)")
                            end
                        else
                            print("  Empty/Air")
                        end
                        
                        -- Send keepalive after each scan
                        sendKeepalive()
                    else
                        print("WARNING: GPS verification failed!")
                        print("  Expected: " .. textutils.serialize(scanPos))
                        print("  Got:      " .. textutils.serialize(verifyPos))
                        totalFailed = totalFailed + 1
                    end
                else
                    totalFailed = totalFailed + 1
                    print("SKIPPED: Could not reach position (Total failed: " .. totalFailed .. "/" .. MAX_TOTAL_FAILURES .. ")")
                    
                    if totalFailed >= MAX_TOTAL_FAILURES then
                        print("")
                        print("!!! TOO MANY FAILURES - ABORTING SCAN !!!")
                        print("Reporting partial results...")
                        print("Pedestals found: " .. #pedestals)
                        print("Stabilizers found: " .. #stabilizers)
                        break
                    end
                end
            end
        end
        
        -- Break outer loop if we aborted
        if totalFailed >= MAX_TOTAL_FAILURES then
            break
        end
        
        print("--- End of row " .. rowIdx .. " ---")
        print("Pedestals so far: " .. #pedestals)
        print("Stabilizers so far: " .. #stabilizers)
    end
    
    print("")
    print("=================================")
    print("SCAN COMPLETE")
    print("=================================")
    print("Total Pedestals: " .. #pedestals)
    print("Total Stabilizers: " .. #stabilizers)
    print("=================================")
    
    return pedestals, stabilizers
end

-- Place item on pedestal (unchanged, works fine)
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

-- Retrieve item
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
        local pedestals, stabilizers = scanPedestalsAroundCatalyst(task.catalystPosition, task.assignedRows)
        
        -- Report results
        print("Sending scan results to server...")
        modem.transmit(CHANNEL, CHANNEL, {
            type = "pedestals_scanned",
            data = {
                altarId = task.altarId,
                pedestalPositions = pedestals,
                stabilizerPositions = stabilizers,
                turtleId = assignedId
            }
        })
        
        -- Return home
        return returnHome()
        
    elseif task.type == "place_catalyst" then
        updateStatus("working", "placing catalyst")
        local result = placeItemOnPedestal(task.item, task.position, task.chestPosition)
        returnHome()
        return result
        
    elseif task.type == "place_ingredient" then
        updateStatus("working", "placing ingredient")
        local result = placeItemOnPedestal(task.item, task.position, task.chestPosition)
        returnHome()
        return result
        
    elseif task.type == "retrieve_result" then
        updateStatus("working", "retrieving result")
        local result = retrieveItemFromPedestal(task.position, task.meInterfacePosition)
        returnHome()
        return result
        
    elseif task.type == "clear_pedestal" then
        updateStatus("working", "clearing pedestal")
        local result = clearPedestal(task.position, task.meInterfacePosition)
        returnHome()
        return result
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
    
    updateStatus("idle", "waiting")
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
    print("Thaumcraft Turtle Worker v3.2")
    print("=================================")
    
    print("Computer ID: " .. computerID)
    print("Fuel level: " .. turtle.getFuelLevel())
    
    if turtle.getFuelLevel() < 100 then
        print("WARNING: Low fuel!")
    end
    
    local hasSavedId = loadSavedId()
    
    homePosition = getPosition(true)
    if not homePosition then
        error("ERROR: Cannot get GPS position!")
    end
    
    print("Home position: " .. textutils.serialize(homePosition))
    
    if hasSavedId then
        print("Re-registering with ID #" .. assignedId)
        modem.transmit(CHANNEL, CHANNEL, {
            type = "turtle_reregister",
            data = {
                turtleId = assignedId,
                computerId = computerID,
                position = homePosition
            }
        })
    else
        print("Registering as new turtle")
        modem.transmit(CHANNEL, CHANNEL, {
            type = "turtle_register",
            data = {
                computerID = computerID,
                position = homePosition
            }
        })
    end
    
    print("Waiting for confirmation...")
    
    local registerTimer = os.startTimer(5)
    local keepaliveTimer = os.startTimer(30) -- Keepalive every 30 seconds
    
    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent()
        
        if event == "modem_message" and channel == CHANNEL then
            handleMessage(message)
            
        elseif event == "timer" then
            if side == registerTimer then
                if not assignedId then
                    modem.transmit(CHANNEL, CHANNEL, {
                        type = "turtle_register",
                        data = {
                            computerId = computerID,
                            position = homePosition
                        }
                    })
                end
                registerTimer = os.startTimer(5)
                
            elseif side == keepaliveTimer then
                sendKeepalive()
                keepaliveTimer = os.startTimer(30) -- Keepalive every 30 seconds
            end
        end
    end
end

main()
