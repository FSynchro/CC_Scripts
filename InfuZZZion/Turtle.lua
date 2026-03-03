-- Thaumcraft Infusion Turtle Worker v3.3
-- FIXED: Added refueling logic from chest using coal/charcoal

local CHANNEL = 1742
local ID_FILE = "turtle_id.dat"
local SCAN_DELAY = 0.5
local MOVE_DELAY = 0.3
local GPS_VERIFY_RETRIES = 3

-- Fuel constants
local MIN_FUEL = 200          -- Minimum fuel to attempt any task
local REFUEL_THRESHOLD = 100  -- Refuel when below this
local REFUEL_SLOT = 16        -- Reserved inventory slot for fuel items
local FUEL_ITEMS = {          -- Items we are allowed to consume as fuel
    ["minecraft:coal"] = true,
    ["minecraft:charcoal"] = true,
    ["minecraft:coal_block"] = true,
}

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
        if currentPosition then
            print("WARNING: GPS failed, using cached position")
            return currentPosition
        end
        return nil
    end
    return currentPosition
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

-- Turn to face direction (shortest path)
local function turnToFace(targetFacing)
    if facing == targetFacing then return end
    local diff = (targetFacing - facing) % 4
    if diff == 1 or diff == -3 then
        turtle.turnRight()
        facing = (facing + 1) % 4
        sleep(MOVE_DELAY)
    elseif diff == 2 or diff == -2 then
        turtle.turnRight()
        facing = (facing + 1) % 4
        sleep(MOVE_DELAY)
        turtle.turnRight()
        facing = (facing + 1) % 4
        sleep(MOVE_DELAY)
    elseif diff == 3 or diff == -1 then
        turtle.turnLeft()
        facing = (facing - 1) % 4
        sleep(MOVE_DELAY)
    end
end

-- Safe movement
local function moveForward()
    if not turtle.forward() then
        turtle.dig()
        sleep(0.2)
        if not turtle.forward() then return false end
    end
    sleep(MOVE_DELAY)
    return true
end

local function moveUp()
    if not turtle.up() then
        turtle.digUp()
        sleep(0.2)
        if not turtle.up() then return false end
    end
    sleep(MOVE_DELAY)
    return true
end

local function moveDown()
    if not turtle.down() then
        turtle.digDown()
        sleep(0.2)
        if not turtle.down() then return false end
    end
    sleep(MOVE_DELAY)
    return true
end

-- ============================================================
-- REFUELING LOGIC
-- ============================================================

-- Check if an item name is a valid fuel item
local function isFuelItem(itemName)
    if not itemName then return false end
    return FUEL_ITEMS[itemName] == true
end

-- Find fuel in the chest below and move it to REFUEL_SLOT.
-- Returns true if fuel was found, false otherwise.
-- IMPORTANT: Only picks up recognised fuel items, never ingredients.
local function findFuelInChest(chest)
    if not chest or not chest.list then return false end

    for slot, item in pairs(chest.list()) do
        if isFuelItem(item.name) then
            -- Push one stack into our REFUEL_SLOT
            -- pushItems(toName, fromSlot, limit, toSlot)
            local moved = chest.pushItems(peripheral.getName(turtle) or "turtle", slot, 64, REFUEL_SLOT)
            if moved and moved > 0 then
                print("Pulled " .. moved .. "x " .. item.name .. " into slot " .. REFUEL_SLOT)
                return true
            end
        end
    end
    return false
end

-- Refuel the turtle from its own inventory slot REFUEL_SLOT only.
-- Returns true if we now have enough fuel.
local function refuelFromSlot()
    turtle.select(REFUEL_SLOT)
    local detail = turtle.getItemDetail()
    if detail and isFuelItem(detail.name) then
        turtle.refuel()  -- consumes entire stack for max fuel gain
        print("Refuelled! Fuel now: " .. turtle.getFuelLevel())
    end
    turtle.select(1)
    return turtle.getFuelLevel() >= MIN_FUEL
end

-- Full refuel sequence: go above chest, grab coal, refuel, return.
-- Called whenever fuel drops below REFUEL_THRESHOLD before a task.
local function doRefuel()
    if not chestPosition then
        print("ERROR: No chest position known, cannot refuel!")
        return false
    end

    print("LOW FUEL (" .. turtle.getFuelLevel() .. ") - heading to chest to refuel...")
    updateStatus("refuelling", "going to chest")

    -- First clear out REFUEL_SLOT if it has stray items (shouldn't happen, but safety)
    local existing = turtle.getItemDetail(REFUEL_SLOT)
    if existing and not isFuelItem(existing.name) then
        print("WARNING: Non-fuel item found in REFUEL_SLOT " .. REFUEL_SLOT .. ": " .. existing.name)
        print("Please clear slot " .. REFUEL_SLOT .. " manually. Aborting refuel.")
        return false
    end

    -- Move to position directly above the chest
    local chestAbovePos = {
        x = chestPosition.x,
        y = chestPosition.y + 1,
        z = chestPosition.z
    }

    -- We need at least a tiny bit of fuel to reach the chest.
    -- If we truly have 0 fuel we cannot move at all.
    if turtle.getFuelLevel() == 0 then
        print("CRITICAL: Zero fuel, cannot move to chest!")
        return false
    end

    if not moveTo(chestAbovePos) then
        print("ERROR: Cannot reach chest to refuel!")
        return false
    end

    -- Access the chest below
    local chest = peripheral.wrap("bottom")
    if not chest or not chest.list then
        print("ERROR: No chest found below at refuel position!")
        return false
    end

    -- Grab coal into REFUEL_SLOT
    if not findFuelInChest(chest) then
        -- Try sucking directly (works when chest.pushItems isn't available)
        print("pushItems unavailable, trying suckDown...")
        -- Make sure REFUEL_SLOT is selected and temporarily allow suck
        turtle.select(REFUEL_SLOT)
        -- Peek at chest to find a fuel item slot
        local found = false
        for slot, item in pairs(chest.list()) do
            if isFuelItem(item.name) then
                -- We can't suck a specific slot, so check what comes up
                found = true
                break
            end
        end

        if found then
            -- suckDown grabs from the first available slot; we rely on the
            -- chest only having fuel here, or we verify after.
            if turtle.suckDown(64) then
                local sucked = turtle.getItemDetail(REFUEL_SLOT)
                if sucked and not isFuelItem(sucked.name) then
                    -- Wrong item! Put it back immediately.
                    print("ERROR: Sucked non-fuel item " .. sucked.name .. "! Returning it.")
                    turtle.dropDown(turtle.getItemCount(REFUEL_SLOT))
                    turtle.select(1)
                    return false
                end
                print("Sucked fuel via suckDown")
            end
        else
            print("ERROR: No fuel items found in chest!")
            turtle.select(1)
            return false
        end
        turtle.select(1)
    end

    -- Now refuel
    local ok = refuelFromSlot()

    if ok then
        print("Refuel complete! Fuel: " .. turtle.getFuelLevel())
        updateStatus("idle", "refuelled")
    else
        print("WARNING: Refuel attempted but still low on fuel: " .. turtle.getFuelLevel())
    end

    return ok
end

-- Gate function used before every task / movement sequence.
-- Returns true if fuel is sufficient (refuelling if needed).
local function ensureFuel()
    if turtle.getFuelLevel() >= MIN_FUEL then
        return true
    end
    return doRefuel()
end

-- ============================================================
-- MOVEMENT
-- ============================================================

-- moveTo uses ensureFuel internally via the old checkFuel wrapper,
-- but we replace the old checkFuel with ensureFuel so it actually fixes the problem.
local function moveTo(target)
    -- Ensure we have enough fuel before attempting any movement
    if not ensureFuel() then
        print("ERROR: Cannot get enough fuel to move!")
        return false
    end

    local startPos = getPosition(true)
    if not startPos then
        print("ERROR: Cannot get GPS position!")
        return false
    end

    print("Moving from " .. textutils.serialize(startPos))
    print("         to " .. textutils.serialize(target))

    local MAX_AXIS_ATTEMPTS = 5
    local stuckCounter = 0

    -- Move Y first
    local yAttempts = 0
    while yAttempts < MAX_AXIS_ATTEMPTS do
        local current = getPosition(true)
        if not current then
            print("ERROR: Lost GPS signal!")
            return false
        end
        if current.y == target.y then break end

        if current.y < target.y then
            if moveUp() then stuckCounter = 0
            else
                yAttempts = yAttempts + 1
                stuckCounter = stuckCounter + 1
                if stuckCounter >= 3 then print("ERROR: Stuck moving UP!") return false end
            end
        else
            if moveDown() then stuckCounter = 0
            else
                yAttempts = yAttempts + 1
                stuckCounter = stuckCounter + 1
                if stuckCounter >= 3 then print("ERROR: Stuck moving DOWN!") return false end
            end
        end
        sendKeepalive()
    end
    if yAttempts >= MAX_AXIS_ATTEMPTS then print("ERROR: Cannot reach target Y") return false end

    -- Move X
    local xAttempts = 0
    local justCorrected = false
    stuckCounter = 0

    while xAttempts < MAX_AXIS_ATTEMPTS do
        local current = getPosition(true)
        if not current then print("ERROR: Lost GPS signal!") return false end
        if current.x == target.x then break end

        if current.x < target.x then
            if not justCorrected then turnToFace(1) end
            justCorrected = false
            local beforeDist = math.abs(current.x - target.x)
            if moveForward() then
                stuckCounter = 0
                local afterPos = getPosition(true)
                if afterPos then
                    if math.abs(afterPos.x - target.x) > beforeDist then
                        print("WARNING: Wrong direction on X!")
                        turtle.turnRight() turtle.turnRight()
                        facing = (facing + 2) % 4
                        sleep(MOVE_DELAY)
                        justCorrected = true
                        xAttempts = xAttempts + 1
                    end
                end
            else
                xAttempts = xAttempts + 1
                stuckCounter = stuckCounter + 1
                if stuckCounter >= 3 then print("ERROR: Stuck EAST!") return false end
            end
        else
            if not justCorrected then turnToFace(3) end
            justCorrected = false
            local beforeDist = math.abs(current.x - target.x)
            if moveForward() then
                stuckCounter = 0
                local afterPos = getPosition(true)
                if afterPos then
                    if math.abs(afterPos.x - target.x) > beforeDist then
                        print("WARNING: Wrong direction on X!")
                        turtle.turnRight() turtle.turnRight()
                        facing = (facing + 2) % 4
                        sleep(MOVE_DELAY)
                        justCorrected = true
                        xAttempts = xAttempts + 1
                    end
                end
            else
                xAttempts = xAttempts + 1
                stuckCounter = stuckCounter + 1
                if stuckCounter >= 3 then print("ERROR: Stuck WEST!") return false end
            end
        end
        sendKeepalive()
    end
    if xAttempts >= MAX_AXIS_ATTEMPTS then print("ERROR: Cannot reach target X") return false end

    -- Move Z
    local zAttempts = 0
    justCorrected = false
    stuckCounter = 0

    while zAttempts < MAX_AXIS_ATTEMPTS do
        local current = getPosition(true)
        if not current then print("ERROR: Lost GPS signal!") return false end
        if current.z == target.z then break end

        if current.z < target.z then
            if not justCorrected then turnToFace(2) end
            justCorrected = false
            local beforeDist = math.abs(current.z - target.z)
            if moveForward() then
                stuckCounter = 0
                local afterPos = getPosition(true)
                if afterPos then
                    if math.abs(afterPos.z - target.z) > beforeDist then
                        print("WARNING: Wrong direction on Z!")
                        turtle.turnRight() turtle.turnRight()
                        facing = (facing + 2) % 4
                        sleep(MOVE_DELAY)
                        justCorrected = true
                        zAttempts = zAttempts + 1
                    end
                end
            else
                zAttempts = zAttempts + 1
                stuckCounter = stuckCounter + 1
                if stuckCounter >= 3 then print("ERROR: Stuck SOUTH!") return false end
            end
        else
            if not justCorrected then turnToFace(0) end
            justCorrected = false
            local beforeDist = math.abs(current.z - target.z)
            if moveForward() then
                stuckCounter = 0
                local afterPos = getPosition(true)
                if afterPos then
                    if math.abs(afterPos.z - target.z) > beforeDist then
                        print("WARNING: Wrong direction on Z!")
                        turtle.turnRight() turtle.turnRight()
                        facing = (facing + 2) % 4
                        sleep(MOVE_DELAY)
                        justCorrected = true
                        zAttempts = zAttempts + 1
                    end
                end
            else
                zAttempts = zAttempts + 1
                stuckCounter = stuckCounter + 1
                if stuckCounter >= 3 then print("ERROR: Stuck NORTH!") return false end
            end
        end
        sendKeepalive()
    end
    if zAttempts >= MAX_AXIS_ATTEMPTS then print("ERROR: Cannot reach target Z") return false end

    -- Final verification
    local finalPos = getPosition(true)
    if finalPos then
        currentPosition = finalPos
        if finalPos.x == target.x and finalPos.y == target.y and finalPos.z == target.z then
            return true
        else
            print("ERROR: Position mismatch!")
            print("  Target: " .. textutils.serialize(target))
            print("  Actual: " .. textutils.serialize(finalPos))
            return false
        end
    end

    print("ERROR: GPS verification failed!")
    return false
end

-- ============================================================
-- HOME / RETURN
-- ============================================================

local function returnHome()
    if homePosition then
        print("Returning home...")
        updateStatus("returning", "going to home position")

        local current = getPosition(true)
        if not current then
            print("ERROR: Cannot get GPS for return!")
            return false
        end

        local intermediatePos = {
            x = homePosition.x,
            y = current.y,
            z = homePosition.z
        }

        if not moveTo(intermediatePos) then
            print("ERROR: Cannot reach home X,Z!")
            return false
        end

        if not moveTo(homePosition) then
            print("ERROR: Cannot reach home Y!")
            return false
        end

        print("Home!")
        saveId()
        updateStatus("idle", "waiting")
        sendKeepalive()
        return true
    end
    return false
end

-- ============================================================
-- SCANNING
-- ============================================================

local function isStabilizer(blockName)
    if not blockName then return false end
    local lowerName = blockName:lower()
    return lowerName:find("skull") or lowerName:find("head") or lowerName:find("candle")
end

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

    local flyingY = catalystPos.y + 2
    print("Flying at Y=" .. flyingY .. " (2 above catalyst)")

    local totalFailed = 0
    local MAX_TOTAL_FAILURES = 10

    for rowIdx, zOffset in ipairs(assignedRows) do
        print("Row " .. rowIdx .. "/" .. #assignedRows .. " (Z=" .. zOffset .. ")...")

        for xOffset = -3, 3 do
            if not (xOffset == 0 and zOffset == 0) then
                -- Refuel check between scan positions to avoid running dry mid-scan
                if turtle.getFuelLevel() < REFUEL_THRESHOLD then
                    print("Fuel low during scan, pausing to refuel...")
                    if not doRefuel() then
                        print("ERROR: Could not refuel during scan!")
                    end
                end

                local scanPos = {
                    x = catalystPos.x + xOffset,
                    y = flyingY,
                    z = catalystPos.z + zOffset
                }

                if moveTo(scanPos) then
                    local verifyPos = getPosition(true)
                    if verifyPos and
                       verifyPos.x == scanPos.x and
                       verifyPos.y == scanPos.y and
                       verifyPos.z == scanPos.z then

                        sleep(SCAN_DELAY)

                        local success, block = turtle.inspectDown()

                        if success and block.name then
                            local itemPos = {
                                x = verifyPos.x,
                                y = verifyPos.y - 1,
                                z = verifyPos.z
                            }
                            local posKey = itemPos.x .. "," .. itemPos.y .. "," .. itemPos.z

                            if block.name:find("edestal") then
                                if not foundPedestals[posKey] then
                                    foundPedestals[posKey] = true
                                    table.insert(pedestals, itemPos)
                                    print("  Found PEDESTAL at [" .. xOffset .. "," .. zOffset .. "]")
                                end
                            elseif isStabilizer(block.name) then
                                if not foundStabilizers[posKey] then
                                    foundStabilizers[posKey] = true
                                    table.insert(stabilizers, itemPos)
                                    print("  Found STABILIZER at [" .. xOffset .. "," .. zOffset .. "]")
                                end
                            end
                        end

                        sendKeepalive()
                    else
                        totalFailed = totalFailed + 1
                    end
                else
                    totalFailed = totalFailed + 1
                    print("  Skipped [" .. xOffset .. "," .. zOffset .. "] (Failed: " .. totalFailed .. "/" .. MAX_TOTAL_FAILURES .. ")")
                    if totalFailed >= MAX_TOTAL_FAILURES then
                        print("TOO MANY FAILURES - Aborting scan")
                        break
                    end
                end
            end
        end

        if totalFailed >= MAX_TOTAL_FAILURES then break end

        print("--- End of row " .. rowIdx .. " ---")
        print("Pedestals so far: " .. #pedestals)
        print("Stabilizers so far: " .. #stabilizers)
    end

    print("")
    print("=================================")
    print("SCAN COMPLETE")
    print("Total Pedestals: " .. #pedestals)
    print("Total Stabilizers: " .. #stabilizers)
    print("=================================")

    return pedestals, stabilizers
end

-- ============================================================
-- ITEM HANDLING  (coal-safe: only pick from correct chest slot)
-- ============================================================

-- Pick up a specific item from the chest.
-- Uses pushItems so we pull exactly the item we want into slot 1.
-- NEVER touches fuel items from recipe ingredients.
local function pickupItemFromChest(item, chestPos)
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

    -- Find the matching item slot
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

    -- Select slot 1 for the ingredient (REFUEL_SLOT is reserved for fuel)
    turtle.select(1)

    -- Try pushItems first (precise slot targeting, no accidental coal pickup)
    local turtleName = peripheral.getName and peripheral.getName(turtle)
    if turtleName then
        local moved = chest.pushItems(turtleName, itemSlot, 1, 1)
        if moved and moved > 0 then
            print("Picked up item via pushItems")
            return true
        end
    end

    -- Fallback: suckDown then verify we got the right item
    -- (only safe if chest contains only one type of item in that slot)
    if not turtle.suckDown(1) then
        print("ERROR: Cannot suck item from chest")
        return false
    end

    -- Verify we picked up the right item and NOT coal accidentally
    local pickedUp = turtle.getItemDetail(1)
    if pickedUp then
        if isFuelItem(pickedUp.name) and pickedUp.name ~= item.item.name then
            -- We accidentally grabbed fuel! Return it immediately.
            print("ERROR: Accidentally picked up fuel item " .. pickedUp.name .. "! Returning.")
            turtle.dropDown(1)
            return false
        end
        if pickedUp.name ~= item.item.name then
            print("ERROR: Wrong item sucked up: " .. pickedUp.name .. " (wanted " .. item.item.name .. ")")
            turtle.dropDown(1)
            return false
        end
    end

    print("Picked up item from chest")
    return true
end

local function placeItemOnPedestal(item, position, chestPos)
    print("Placing " .. item.item.name .. " on pedestal at " .. textutils.serialize(position))
    updateStatus("working", "picking up item")

    if not pickupItemFromChest(item, chestPos) then
        return false
    end

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

    turtle.select(1)
    if not turtle.dropDown(1) then
        print("ERROR: Cannot drop item onto pedestal")
        return false
    end

    print("Item placed on pedestal!")
    return true
end

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

    turtle.select(1)
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

    turtle.select(1)
    if not turtle.dropDown(1) then
        print("ERROR: Cannot drop item into ME Interface")
        return false
    end

    print("Result deposited into ME Interface!")
    return true
end

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

    turtle.select(1)
    if turtle.suckDown(1) then
        print("Picked up item from pedestal")

        local meAbovePos = {
            x = mePos.x,
            y = mePos.y + 1,
            z = mePos.z
        }

        if moveTo(meAbovePos) then
            turtle.select(1)
            turtle.dropDown(1)
            print("Item deposited into ME Interface")
        end
    else
        print("No item on pedestal (already cleared)")
    end

    return true
end

-- ============================================================
-- TASK EXECUTION
-- ============================================================

local function executeTask(task)
    print("Executing task: " .. task.type)

    -- Always check/ensure fuel at the start of every task
    if not ensureFuel() then
        print("ERROR: Cannot get fuel to execute task!")
        return false
    end

    if task.type == "scan_pedestals" then
        local pedestals, stabilizers = scanPedestalsAroundCatalyst(task.catalystPosition, task.assignedRows)

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

-- Process task queue
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
    sendKeepalive()
    print("Tasks complete, sent keepalive to server")
end

-- ============================================================
-- MESSAGE HANDLING
-- ============================================================

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
            print("Chest position: " .. textutils.serialize(chestPosition))
            print("ME position:    " .. textutils.serialize(meInterfacePosition))
            print("=================================")
            print("Fuel: " .. turtle.getFuelLevel())
            print("Ready for tasks...")

            -- Immediately top up fuel on registration so we are ready
            if turtle.getFuelLevel() < MIN_FUEL then
                print("Fuel below minimum on startup, refuelling now...")
                doRefuel()
            end
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

-- ============================================================
-- MAIN LOOP
-- ============================================================

local function main()
    print("=================================")
    print("Thaumcraft Turtle Worker v3.3")
    print("=================================")
    print("Computer ID: " .. computerID)
    print("Fuel level:  " .. turtle.getFuelLevel())
    print("REFUEL_SLOT: " .. REFUEL_SLOT .. " (reserved - keep empty or coal only)")
    print("=================================")

    if turtle.getFuelLevel() < 10 then
        print("CRITICAL: Very low fuel! Cannot move to register.")
        print("Please manually add coal to slot " .. REFUEL_SLOT .. " and restart.")
        -- Don't error out; we'll try after registration provides chest coords
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
    local keepaliveTimer = os.startTimer(30)

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
                keepaliveTimer = os.startTimer(30)
            end
        end
    end
end

main()
