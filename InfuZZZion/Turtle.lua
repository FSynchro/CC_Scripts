-- Thaumcraft Infusion Turtle Worker v3.3
-- FIXED: Correct function order so all locals are visible when called

local CHANNEL = 1742
local ID_FILE = "turtle_id.dat"
local SCAN_DELAY = 0.5
local MOVE_DELAY = 0.3
local GPS_VERIFY_RETRIES = 3

-- Fuel constants
local MIN_FUEL = 200          -- Minimum fuel to attempt any task
local REFUEL_THRESHOLD = 100  -- Refuel when below this
local REFUEL_SLOT = 16        -- Reserved inventory slot for fuel items
local FUEL_ITEMS = {
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

-- ============================================================
-- SECTION 1: FILE I/O
-- ============================================================

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

local function saveId()
    local file = fs.open(ID_FILE, "w")
    file.write(textutils.serialize({
        assignedId = assignedId,
        computerID = computerID,
        facing = facing
    }))
    file.close()
end

-- ============================================================
-- SECTION 2: GPS
-- ============================================================

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

-- ============================================================
-- SECTION 3: NETWORKING HELPERS
-- ============================================================

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

-- ============================================================
-- SECTION 4: PRIMITIVE MOVEMENT
-- ============================================================

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
-- SECTION 5: moveTo
-- NOTE: moveTo does NOT call doRefuel to avoid circular dependency.
-- ensureFuel() must be called by higher-level functions before moveTo.
-- ============================================================

local function moveTo(target)
    if turtle.getFuelLevel() == 0 then
        print("ERROR: Zero fuel, cannot move!")
        return false
    end

    local startPos = getPosition(true)
    if not startPos then
        print("ERROR: Cannot get GPS position!")
        return false
    end

    print("Moving to " .. textutils.serialize(target))

    local MAX_AXIS_ATTEMPTS = 5
    local stuckCounter

    -- ---- Y axis ----
    stuckCounter = 0
    local yAttempts = 0
    while yAttempts < MAX_AXIS_ATTEMPTS do
        local current = getPosition(true)
        if not current then print("ERROR: Lost GPS!") return false end
        if current.y == target.y then break end

        if current.y < target.y then
            if moveUp() then
                stuckCounter = 0
            else
                yAttempts = yAttempts + 1
                stuckCounter = stuckCounter + 1
                if stuckCounter >= 3 then print("ERROR: Stuck moving UP!") return false end
            end
        else
            if moveDown() then
                stuckCounter = 0
            else
                yAttempts = yAttempts + 1
                stuckCounter = stuckCounter + 1
                if stuckCounter >= 3 then print("ERROR: Stuck moving DOWN!") return false end
            end
        end
        sendKeepalive()
    end
    if yAttempts >= MAX_AXIS_ATTEMPTS then print("ERROR: Cannot reach target Y") return false end

    -- ---- X axis ----
    stuckCounter = 0
    local xAttempts = 0
    local justCorrected = false
    while xAttempts < MAX_AXIS_ATTEMPTS do
        local current = getPosition(true)
        if not current then print("ERROR: Lost GPS!") return false end
        if current.x == target.x then break end

        if current.x < target.x then
            if not justCorrected then turnToFace(1) end
            justCorrected = false
            local beforeDist = math.abs(current.x - target.x)
            if moveForward() then
                stuckCounter = 0
                local afterPos = getPosition(true)
                if afterPos and math.abs(afterPos.x - target.x) > beforeDist then
                    print("WARNING: Wrong direction on X!")
                    turtle.turnRight() turtle.turnRight()
                    facing = (facing + 2) % 4
                    sleep(MOVE_DELAY)
                    justCorrected = true
                    xAttempts = xAttempts + 1
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
                if afterPos and math.abs(afterPos.x - target.x) > beforeDist then
                    print("WARNING: Wrong direction on X!")
                    turtle.turnRight() turtle.turnRight()
                    facing = (facing + 2) % 4
                    sleep(MOVE_DELAY)
                    justCorrected = true
                    xAttempts = xAttempts + 1
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

    -- ---- Z axis ----
    stuckCounter = 0
    local zAttempts = 0
    justCorrected = false
    while zAttempts < MAX_AXIS_ATTEMPTS do
        local current = getPosition(true)
        if not current then print("ERROR: Lost GPS!") return false end
        if current.z == target.z then break end

        if current.z < target.z then
            if not justCorrected then turnToFace(2) end
            justCorrected = false
            local beforeDist = math.abs(current.z - target.z)
            if moveForward() then
                stuckCounter = 0
                local afterPos = getPosition(true)
                if afterPos and math.abs(afterPos.z - target.z) > beforeDist then
                    print("WARNING: Wrong direction on Z!")
                    turtle.turnRight() turtle.turnRight()
                    facing = (facing + 2) % 4
                    sleep(MOVE_DELAY)
                    justCorrected = true
                    zAttempts = zAttempts + 1
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
                if afterPos and math.abs(afterPos.z - target.z) > beforeDist then
                    print("WARNING: Wrong direction on Z!")
                    turtle.turnRight() turtle.turnRight()
                    facing = (facing + 2) % 4
                    sleep(MOVE_DELAY)
                    justCorrected = true
                    zAttempts = zAttempts + 1
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

    -- Final GPS verification
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
-- SECTION 6: REFUELING  (depends on: moveTo, updateStatus)
-- ============================================================

local function isFuelItem(itemName)
    if not itemName then return false end
    return FUEL_ITEMS[itemName] == true
end

-- Pull a fuel item from chest below into REFUEL_SLOT.
local function findFuelInChest(chest)
    if not chest or not chest.list then return false end

    for slot, item in pairs(chest.list()) do
        if isFuelItem(item.name) then
            -- Try pushItems first (precise, puts item into our chosen slot)
            local ok, moved = pcall(function()
                return chest.pushItems(peripheral.getName(turtle) or "turtle", slot, 64, REFUEL_SLOT)
            end)
            if ok and moved and moved > 0 then
                print("Pulled " .. moved .. "x " .. item.name .. " via pushItems")
                return true
            end
            -- pushItems failed; fall through to suckDown
            break
        end
    end

    -- Fallback: suckDown then verify we got the right thing
    turtle.select(REFUEL_SLOT)
    if turtle.suckDown(64) then
        local sucked = turtle.getItemDetail(REFUEL_SLOT)
        if sucked and isFuelItem(sucked.name) then
            print("Pulled fuel via suckDown: " .. sucked.name)
            turtle.select(1)
            return true
        else
            -- Wrong item, put it back
            if sucked then
                print("ERROR: suckDown got wrong item: " .. sucked.name .. ". Returning.")
            end
            turtle.dropDown(turtle.getItemCount(REFUEL_SLOT))
            turtle.select(1)
            return false
        end
    end

    turtle.select(1)
    return false
end

local function refuelFromSlot()
    turtle.select(REFUEL_SLOT)
    local detail = turtle.getItemDetail()
    if detail and isFuelItem(detail.name) then
        turtle.refuel()
        print("Refuelled! Fuel now: " .. turtle.getFuelLevel())
    end
    turtle.select(1)
    return turtle.getFuelLevel() >= MIN_FUEL
end

local function doRefuel()
    if not chestPosition then
        print("ERROR: No chest position known, cannot refuel!")
        return false
    end

    if turtle.getFuelLevel() == 0 then
        print("CRITICAL: Zero fuel, cannot move to chest!")
        return false
    end

    print("LOW FUEL (" .. turtle.getFuelLevel() .. ") - heading to chest to refuel...")
    updateStatus("refuelling", "going to chest")

    -- Safety: make sure REFUEL_SLOT has no stray non-fuel item
    local existing = turtle.getItemDetail(REFUEL_SLOT)
    if existing and not isFuelItem(existing.name) then
        print("WARNING: Non-fuel item in REFUEL_SLOT " .. REFUEL_SLOT .. ": " .. existing.name)
        print("Please clear slot " .. REFUEL_SLOT .. " manually. Aborting refuel.")
        return false
    end

    local chestAbovePos = {
        x = chestPosition.x,
        y = chestPosition.y + 1,
        z = chestPosition.z
    }

    if not moveTo(chestAbovePos) then
        print("ERROR: Cannot reach chest to refuel!")
        return false
    end

    local chest = peripheral.wrap("bottom")
    if not chest or not chest.list then
        print("ERROR: No chest found below refuel position!")
        return false
    end

    if not findFuelInChest(chest) then
        print("ERROR: No fuel items found in chest!")
        return false
    end

    local ok = refuelFromSlot()
    if ok then
        print("Refuel complete! Fuel: " .. turtle.getFuelLevel())
        updateStatus("idle", "refuelled")
    else
        print("WARNING: Still low after refuel: " .. turtle.getFuelLevel())
    end
    return ok
end

-- Gate used before every task and mid-scan.
local function ensureFuel()
    if turtle.getFuelLevel() >= MIN_FUEL then
        return true
    end
    return doRefuel()
end

-- ============================================================
-- SECTION 7: RETURN HOME  (depends on: moveTo, saveId, updateStatus, sendKeepalive)
-- ============================================================

local function returnHome()
    if not homePosition then return false end

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

-- ============================================================
-- SECTION 8: SCANNING  (depends on: moveTo, doRefuel, returnHome)
-- ============================================================

local function isStabilizer(blockName)
    if not blockName then return false end
    local lowerName = blockName:lower()
    return lowerName:find("skull") or lowerName:find("head") or lowerName:find("candle")
end

local function scanPedestalsAroundCatalyst(catalystPos, assignedRows)
    print("=================================")
    print("STARTING PEDESTAL SCAN")
    print("Catalyst: " .. textutils.serialize(catalystPos))
    print("Rows (Z): " .. textutils.serialize(assignedRows))
    print("Fuel: " .. turtle.getFuelLevel())
    print("=================================")

    updateStatus("scanning", "scanning pedestals")
    sendKeepalive()

    local pedestals = {}
    local stabilizers = {}
    local foundPedestals = {}
    local foundStabilizers = {}

    local flyingY = catalystPos.y + 2
    local totalFailed = 0
    local MAX_TOTAL_FAILURES = 10
    local aborted = false

    for rowIdx, zOffset in ipairs(assignedRows) do
        if aborted then break end

        print("Row " .. rowIdx .. "/" .. #assignedRows .. " (Z=" .. zOffset .. ")...")

        for xOffset = -3, 3 do
            if not aborted then
                -- Skip catalyst centre
                if not (xOffset == 0 and zOffset == 0) then

                    -- Mid-scan refuel check
                    if turtle.getFuelLevel() < REFUEL_THRESHOLD then
                        print("Fuel low during scan (" .. turtle.getFuelLevel() .. "), refuelling...")
                        if not doRefuel() then
                            print("ERROR: Could not refuel during scan, continuing anyway")
                        end
                    end

                    local scanPos = {
                        x = catalystPos.x + xOffset,
                        y = flyingY,
                        z = catalystPos.z + zOffset
                    }

                    if moveTo(scanPos) then
                        local verifyPos = getPosition(true)
                        if verifyPos
                           and verifyPos.x == scanPos.x
                           and verifyPos.y == scanPos.y
                           and verifyPos.z == scanPos.z then

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
                                        print("  PEDESTAL at [" .. xOffset .. "," .. zOffset .. "]")
                                    end
                                elseif isStabilizer(block.name) then
                                    if not foundStabilizers[posKey] then
                                        foundStabilizers[posKey] = true
                                        table.insert(stabilizers, itemPos)
                                        print("  STABILIZER at [" .. xOffset .. "," .. zOffset .. "]")
                                    end
                                end
                            end

                            sendKeepalive()
                        else
                            totalFailed = totalFailed + 1
                        end
                    else
                        totalFailed = totalFailed + 1
                        print("  Skipped [" .. xOffset .. "," .. zOffset .. "] (" .. totalFailed .. "/" .. MAX_TOTAL_FAILURES .. ")")
                        if totalFailed >= MAX_TOTAL_FAILURES then
                            print("TOO MANY FAILURES - Aborting scan")
                            aborted = true
                        end
                    end
                end
            end
        end

        if not aborted then
            print("End of row " .. rowIdx .. " | Pedestals: " .. #pedestals .. " Stabilizers: " .. #stabilizers)
        end
    end

    print("=================================")
    print("SCAN COMPLETE")
    print("Total Pedestals: " .. #pedestals)
    print("Total Stabilizers: " .. #stabilizers)
    print("=================================")

    return pedestals, stabilizers
end

-- ============================================================
-- SECTION 9: ITEM HANDLING  (depends on: moveTo, isFuelItem)
-- ============================================================

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

    -- Locate the correct slot
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

    turtle.select(1)

    -- Try pushItems first (precise slot targeting)
    local ok, moved = pcall(function()
        return chest.pushItems(peripheral.getName(turtle) or "turtle", itemSlot, 1, 1)
    end)
    if ok and moved and moved > 0 then
        print("Picked up " .. item.item.name .. " via pushItems")
        return true
    end

    -- Fallback: suckDown with post-check
    if not turtle.suckDown(1) then
        print("ERROR: Cannot suck item from chest")
        return false
    end

    local pickedUp = turtle.getItemDetail(1)
    if pickedUp then
        if isFuelItem(pickedUp.name) and pickedUp.name ~= item.item.name then
            print("ERROR: Grabbed fuel item " .. pickedUp.name .. " instead of " .. item.item.name .. ". Returning.")
            turtle.dropDown(1)
            return false
        end
        if pickedUp.name ~= item.item.name then
            print("ERROR: Wrong item: got " .. pickedUp.name .. " wanted " .. item.item.name .. ". Returning.")
            turtle.dropDown(1)
            return false
        end
    end

    print("Picked up " .. item.item.name)
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

    print("Item placed!")
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
        print("ERROR: Cannot drop into ME Interface")
        return false
    end

    print("Result deposited!")
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
        local meAbovePos = {
            x = mePos.x,
            y = mePos.y + 1,
            z = mePos.z
        }
        if moveTo(meAbovePos) then
            turtle.select(1)
            turtle.dropDown(1)
            print("Pedestal cleared, item deposited")
        end
    else
        print("Pedestal already empty")
    end

    return true
end

-- ============================================================
-- SECTION 10: TASK EXECUTION  (depends on everything above)
-- ============================================================

local function executeTask(task)
    print("Executing task: " .. task.type)

    if not ensureFuel() then
        print("ERROR: Cannot get fuel to execute task!")
        return false
    end

    if task.type == "scan_pedestals" then
        local pedestals, stabilizers = scanPedestalsAroundCatalyst(task.catalystPosition, task.assignedRows)

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
    print("Tasks complete")
end

-- ============================================================
-- SECTION 10.5: CHEST/ME DISCOVERY
-- Called once after registration. Moves to 2 above the server computer,
-- then checks each of the 4 cardinal neighbours by dipping to Y+1 and
-- inspecting the block below. Once the chest is found the ME interface
-- is assumed to be one block further in the same direction.
-- Reports results back to the server via "chest_found".
-- ============================================================

-- Offsets for North/East/South/West: {dx, dz}
local CARDINAL_OFFSETS = {
    {dx =  0, dz = -1},  -- North
    {dx =  1, dz =  0},  -- East
    {dx =  0, dz =  1},  -- South
    {dx = -1, dz =  0},  -- West
}

local function findChestAroundServer(serverPos)
    print("=================================")
    print("SEARCHING FOR CHEST/ME INTERFACE")
    print("Server pos: " .. textutils.serialize(serverPos))
    print("=================================")

    updateStatus("searching", "finding chest")

    -- Hover point: 2 above the server
    local hoverPos = {
        x = serverPos.x,
        y = serverPos.y + 2,
        z = serverPos.z
    }

    for _, offset in ipairs(CARDINAL_OFFSETS) do
        -- Return to hover above server before each side check
        if not moveTo(hoverPos) then
            print("ERROR: Cannot reach hover position above server!")
            return false
        end

        -- Move to the side at Y+1 (one below hover) so inspectDown
        -- looks at the server's Y level
        local sidePos = {
            x = serverPos.x + offset.dx,
            y = serverPos.y + 1,
            z = serverPos.z + offset.dz
        }

        if moveTo(sidePos) then
            local success, block = turtle.inspectDown()
            if success and block.name then
                print("  Side [" .. offset.dx .. "," .. offset.dz .. "]: " .. block.name)

                if block.name:find("chest") or block.name:find("Chest") then
                    -- Found the chest
                    local foundChest = {
                        x = serverPos.x + offset.dx,
                        y = serverPos.y,
                        z = serverPos.z + offset.dz
                    }
                    -- ME interface is one block further in the same direction
                    local foundME = {
                        x = serverPos.x + offset.dx * 2,
                        y = serverPos.y,
                        z = serverPos.z + offset.dz * 2
                    }

                    print("FOUND CHEST at " .. textutils.serialize(foundChest))
                    print("ME interface at " .. textutils.serialize(foundME))

                    chestPosition = foundChest
                    meInterfacePosition = foundME

                    -- Report to server
                    modem.transmit(CHANNEL, CHANNEL, {
                        type = "chest_found",
                        data = {
                            turtleId = assignedId,
                            chestPosition = foundChest,
                            meInterfacePosition = foundME
                        }
                    })

                    -- Return to hover then home
                    moveTo(hoverPos)
                    return true
                end
            else
                print("  Side [" .. offset.dx .. "," .. offset.dz .. "]: empty")
            end
        else
            print("  WARNING: Could not reach side [" .. offset.dx .. "," .. offset.dz .. "]")
        end
    end

    -- Return to hover before giving up
    moveTo(hoverPos)
    print("ERROR: No chest found around server!")
    return false
end

-- ============================================================
-- SECTION 11: MESSAGE HANDLING
-- ============================================================

local function handleMessage(msg)
    if type(msg) ~= "table" or not msg.type then return end

    if msg.type == "turtle_id_assigned" then
        if msg.data.computerId == computerID then
            assignedId = msg.data.assignedId
            -- chestPosition and meInterfacePosition are NOT sent from server anymore.
            -- The turtle discovers them itself via findChestAroundServer().

            saveId()

            print("")
            print("=================================")
            print("Assigned ID: #" .. assignedId)
            print("Fuel:   " .. turtle.getFuelLevel())
            print("=================================")

            -- If server already knows chest position (e.g. from a previous turtle
            -- that reported it), it sends it along so we skip the scan.
            if msg.data.chestPosition then
                chestPosition = msg.data.chestPosition
                meInterfacePosition = msg.data.meInterfacePosition
                print("Chest pos from server: " .. textutils.serialize(chestPosition))
                print("ME pos from server:    " .. textutils.serialize(meInterfacePosition))
            elseif msg.data.serverPosition then
                -- Need to discover it ourselves
                print("Discovering chest/ME around server...")
                if not findChestAroundServer(msg.data.serverPosition) then
                    print("ERROR: Could not find chest! Tasks will fail until chest is found.")
                end
            else
                print("WARNING: No server position provided, chest location unknown.")
            end

            -- Top up fuel now that we (may) know where the chest is
            if turtle.getFuelLevel() < MIN_FUEL then
                print("Fuel below minimum, refuelling now...")
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
        print("DISASTER ABORT!")
        tasks = {}
        updateStatus("idle", "aborted")
        returnHome()
    end
end

-- ============================================================
-- SECTION 12: MAIN LOOP
-- ============================================================

local function main()
    print("=================================")
    print("Thaumcraft Turtle Worker v3.3")
    print("=================================")
    print("Computer ID: " .. computerID)
    print("Fuel:        " .. turtle.getFuelLevel())
    print("REFUEL_SLOT: " .. REFUEL_SLOT .. " (keep empty or coal only)")
    print("=================================")

    if turtle.getFuelLevel() < 10 then
        print("WARNING: Very low fuel!")
        print("Add coal to slot " .. REFUEL_SLOT .. " if turtle cannot reach chest.")
    end

    local hasSavedId = loadSavedId()

    homePosition = getPosition(true)
    if not homePosition then
        error("ERROR: Cannot get GPS position!")
    end

    print("Home: " .. textutils.serialize(homePosition))

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

    print("Waiting for server...")

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
