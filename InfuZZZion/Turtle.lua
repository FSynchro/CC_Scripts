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
--
-- Design principles:
--   1. GPS is the single source of truth. We never dead-reckon.
--   2. After every successful moveForward(), we take a GPS reading and
--      derive the direction we ACTUALLY moved. This updates `facing` to
--      match reality, so turnToFace() always has a correct baseline.
--   3. No "justCorrected" flag needed — because `facing` is always correct
--      after a move, turnToFace() will simply do the right thing next time.
--   4. MAX_STEPS is based on Manhattan distance so long paths never time out.
--
-- Facing convention: 0=North(-Z), 1=East(+X), 2=South(+Z), 3=West(-X)
-- ============================================================

-- Derive the facing we must have had when we moved from `before` to `after`.
-- Returns nil if the move didn't change X or Z (i.e. Y move or no move).
local function facingFromMove(before, after)
    local dx = after.x - before.x
    local dz = after.z - before.z
    if dx == 1  then return 1 end  -- East
    if dx == -1 then return 3 end  -- West
    if dz == 1  then return 2 end  -- South
    if dz == -1 then return 0 end  -- North
    return nil  -- no horizontal movement detected
end

local function moveTo(target)
    if turtle.getFuelLevel() == 0 then
        print("ERROR: Zero fuel, cannot move!")
        return false
    end

    local pos = getPosition(true)
    if not pos then
        print("ERROR: Cannot get GPS position!")
        return false
    end

    print("Moving to " .. textutils.serialize(target))

    -- Instead of a fixed step budget calculated once at the start (which fails
    -- if the turtle overshoots and has to backtrack), we track how many
    -- consecutive iterations make NO progress toward the target. If the
    -- remaining Manhattan distance doesn't shrink for MAX_IDLE iterations,
    -- we declare it stuck and bail out.
    local MAX_IDLE = 16
    local idleCount = 0
    local lastDist = math.abs(target.x - pos.x)
                   + math.abs(target.y - pos.y)
                   + math.abs(target.z - pos.z)
    local stuckCount = 0

    while true do
        pos = getPosition(true)
        if not pos then print("ERROR: Lost GPS!") return false end

        -- Check if we have arrived
        if pos.x == target.x and pos.y == target.y and pos.z == target.z then
            return true
        end

        -- Check progress: if Manhattan distance shrank we're making headway
        local dist = math.abs(target.x - pos.x)
                   + math.abs(target.y - pos.y)
                   + math.abs(target.z - pos.z)
        if dist < lastDist then
            idleCount = 0
            lastDist = dist
        else
            idleCount = idleCount + 1
            if idleCount >= MAX_IDLE then
                print("ERROR: moveTo exceeded max steps!")
                print("  Target: " .. textutils.serialize(target))
                print("  Actual: " .. textutils.serialize(pos))
                return false
            end
        end

        -- Decide which axis to work on:
        -- Ascend first (clear obstacles), then X, then Z, then descend last.
        if pos.y < target.y then
            -- Need to go up — do this before any horizontal movement
            if not moveUp() then
                stuckCount = stuckCount + 1
                if stuckCount >= 5 then print("ERROR: Stuck going up!") return false end
            else
                stuckCount = 0
            end

        elseif pos.x ~= target.x then
            -- Need to move on X axis
            local wantFacing = pos.x < target.x and 1 or 3
            turnToFace(wantFacing)

            if moveForward() then
                stuckCount = 0
                -- Trust the intended direction; update facing and dead-reckon pos.
                -- GPS will correct on next loop iteration if we drifted.
                facing = wantFacing
                pos = {
                    x = pos.x + (wantFacing == 1 and 1 or -1),
                    y = pos.y,
                    z = pos.z
                }
            else
                stuckCount = stuckCount + 1
                if stuckCount >= 5 then print("ERROR: Stuck on X axis!") return false end
            end

        elseif pos.z ~= target.z then
            -- Need to move on Z axis
            local wantFacing = pos.z < target.z and 2 or 0
            turnToFace(wantFacing)

            if moveForward() then
                stuckCount = 0
                -- Trust the intended direction; update facing and dead-reckon pos.
                facing = wantFacing
                pos = {
                    x = pos.x,
                    y = pos.y,
                    z = pos.z + (wantFacing == 2 and 1 or -1)
                }
            else
                stuckCount = stuckCount + 1
                if stuckCount >= 5 then print("ERROR: Stuck on Z axis!") return false end
            end

        elseif pos.y > target.y then
            -- Descend last, once X and Z are already correct
            if not moveDown() then
                stuckCount = stuckCount + 1
                if stuckCount >= 5 then print("ERROR: Stuck going down!") return false end
            else
                stuckCount = 0
            end
        end

        sendKeepalive()
    end
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
    -- Scan all 16 slots for any fuel item, not just REFUEL_SLOT
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and isFuelItem(detail.name) then
            turtle.select(slot)
            turtle.refuel()
            print("Refuelled from slot " .. slot .. " (" .. detail.name .. ")! Fuel now: " .. turtle.getFuelLevel())
            if turtle.getFuelLevel() >= MIN_FUEL then
                turtle.select(1)
                return true
            end
        end
    end
    turtle.select(1)
    return turtle.getFuelLevel() >= MIN_FUEL
end

local function doRefuel()
    -- Always try inventory first — works even at zero fuel, no movement needed.
    print("Checking inventory for fuel...")
    if refuelFromSlot() then
        print("Refuelled from inventory! Fuel: " .. turtle.getFuelLevel())
        updateStatus("idle", "refuelled")
        return true
    end

    -- Nothing in inventory; need to travel to the ME interface.
    local refuelPos = meInterfacePosition
    if not refuelPos then
        print("ERROR: ME interface position not known yet, cannot refuel!")
        return false
    end

    if turtle.getFuelLevel() == 0 then
        print("CRITICAL: Zero fuel and no coal in inventory, cannot move to ME interface!")
        return false
    end

    print("Nothing usable in inventory, heading to ME interface...")
    updateStatus("refuelling", "going to ME interface")

    local meAbovePos = {
        x = refuelPos.x,
        y = refuelPos.y + 1,
        z = refuelPos.z
    }

    if not moveTo(meAbovePos) then
        print("ERROR: Cannot reach ME interface to refuel!")
        return false
    end

    local me = peripheral.wrap("bottom")
    if not me or not me.list then
        print("ERROR: No ME interface found below refuel position!")
        return false
    end

    if not findFuelInChest(me) then
        print("ERROR: No fuel items (coal/charcoal) found in ME interface!")
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
-- SECTION 8: BLOCK INSPECTION HELPERS
--
-- inspectBelow(targetPos):
--   Moves to one block ABOVE targetPos, calls turtle.inspectDown(),
--   returns (success, blockData). Used for both chest detection and
--   pedestal scanning — the single place that knows about Y+1 geometry.
--
-- blockMatches(blockName, patterns):
--   Case-insensitive substring match against a list of patterns.
--   All "is this a chest / pedestal / stabilizer" logic lives here.
-- ============================================================

local function blockMatches(blockName, patterns)
    if not blockName then return false end
    local lower = blockName:lower()
    for _, pattern in ipairs(patterns) do
        if lower:find(pattern:lower()) then
            return true
        end
    end
    return false
end

-- Pattern tables — edit these if mod block names differ
local CHEST_PATTERNS      = {"chest"}
local PEDESTAL_PATTERNS   = {"pedestal"}
local STABILIZER_PATTERNS = {"skull", "head", "candle"}
local ME_INTERFACE_PATTERNS = {"me_interface", "interface", "appeng", "ae2"}

local function inspectBelow(targetPos)
    -- Travel at y+2 so the turtle clears pedestals and altar structures
    -- when moving between scan positions. Then step down to y+1 to inspect.
    local transitPos = {
        x = targetPos.x,
        y = targetPos.y + 2,
        z = targetPos.z
    }
    local abovePos = {
        x = targetPos.x,
        y = targetPos.y + 1,
        z = targetPos.z
    }

    if not moveTo(transitPos) then
        print("  inspectBelow: could not reach transit above " .. textutils.serialize(targetPos))
        return false, nil
    end

    if not moveTo(abovePos) then
        print("  inspectBelow: could not descend to inspect above " .. textutils.serialize(targetPos))
        return false, nil
    end

    sleep(SCAN_DELAY)
    local success, block = turtle.inspectDown()
    if success and block and block.name then
        print("  inspectBelow " .. textutils.serialize(targetPos) .. " => " .. block.name)
        return true, block
    end

    print("  inspectBelow " .. textutils.serialize(targetPos) .. " => (nothing)")
    -- Return true with nil block — position was reached, just nothing there
    return true, nil
end

-- ============================================================
-- SECTION 9: SCANNING  (depends on: moveTo, doRefuel, inspectBelow, blockMatches)
-- ============================================================

local function isStabilizer(blockName)
    return blockMatches(blockName, STABILIZER_PATTERNS)
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

    -- Before entering the scan grid, ascend to catalystPos.y+2 if we are
    -- already within the altar's footprint (within 5 blocks on X or Z).
    -- This ensures we clear the pedestals before moving horizontally.
    local startPos = getPosition(true)
    if startPos then
        local dxStart = math.abs(startPos.x - catalystPos.x)
        local dzStart = math.abs(startPos.z - catalystPos.z)
        if dxStart <= 5 and dzStart <= 5 then
            print("Within altar range, ascending to clear pedestals...")
            moveTo({ x = startPos.x, y = catalystPos.y + 2, z = startPos.z })
        end
    end

    for rowIdx, zOffset in ipairs(assignedRows) do
        print("Row " .. rowIdx .. "/" .. #assignedRows .. " (Z=" .. zOffset .. ")...")

        for xOffset = -3, 3 do
            if not (xOffset == 0 and zOffset == 0) then

                if turtle.getFuelLevel() < REFUEL_THRESHOLD then
                    print("Fuel low during scan (" .. turtle.getFuelLevel() .. "), refuelling...")
                    if not doRefuel() then
                        print("WARNING: Could not refuel during scan, continuing")
                    end
                end

                -- Hover 2 above the pedestal level to clear the pedestal tops,
                -- then inspect down onto the pedestal surface (catalystPos.y).
                local hoverPos = {
                    x = catalystPos.x + xOffset,
                    y = catalystPos.y + 2,
                    z = catalystPos.z + zOffset
                }

                local reached = moveTo(hoverPos)
                local block = nil
                if reached then
                    sleep(SCAN_DELAY)
                    local ok, b = turtle.inspectDown()
                    if ok and b and b.name then block = b end
                end

                if not reached then
                    print("  WARNING: Could not reach [" .. xOffset .. "," .. zOffset .. "], continuing scan")
                elseif block then
                    -- The actual pedestal is 2 below the hover position
                    local pedestalPos = {
                        x = hoverPos.x,
                        y = hoverPos.y - 2,
                        z = hoverPos.z
                    }
                    local posKey = pedestalPos.x .. "," .. pedestalPos.y .. "," .. pedestalPos.z

                    if blockMatches(block.name, PEDESTAL_PATTERNS) then
                        if not foundPedestals[posKey] then
                            foundPedestals[posKey] = true
                            table.insert(pedestals, pedestalPos)
                            print("  PEDESTAL at [" .. xOffset .. "," .. zOffset .. "]")
                        end
                    elseif blockMatches(block.name, STABILIZER_PATTERNS) then
                        if not foundStabilizers[posKey] then
                            foundStabilizers[posKey] = true
                            table.insert(stabilizers, pedestalPos)
                            print("  STABILIZER at [" .. xOffset .. "," .. zOffset .. "]")
                        end
                    end
                end

                sendKeepalive()
            end
        end

        print("End of row " .. rowIdx .. " | Pedestals: " .. #pedestals .. " Stabilizers: " .. #stabilizers)
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
-- SECTION 10.6: CHEST/ME DISCOVERY
--
-- Layout: server → chest (1 block to one side) → ME interface (1 further)
--
-- The block directly above the server is occupied, so we must never
-- route through serverPos.y+1 above the server itself.
--
-- Strategy: for each cardinal direction, approach from 2 blocks out
-- at serverPos.y+1 (safely beside the server, not above it), then
-- use turtle.inspect() to look horizontally at the candidate chest
-- position which is 1 block ahead at the same Y.
-- We never fly over or through the server's occupied airspace.
-- After the scan (found or not) we return home.
-- ============================================================

local CARDINAL_OFFSETS = {
    {dx =  0, dz = -1, name = "North", face = 0},
    {dx =  1, dz =  0, name = "East",  face = 1},
    {dx =  0, dz =  1, name = "South", face = 2},
    {dx = -1, dz =  0, name = "West",  face = 3},
}

local function findChestAroundServer(serverPos)
    print("=================================")
    print("SEARCHING FOR CHEST/ME INTERFACE")
    print("Server pos: " .. textutils.serialize(serverPos))
    print("=================================")

    updateStatus("searching", "finding chest")

    local foundChest = nil
    local foundME    = nil

    for _, offset in ipairs(CARDINAL_OFFSETS) do
        print("Checking " .. offset.name .. " side...")

        -- Transit at serverPos.y+2 to clear the server and its top block.
        -- Then descend to serverPos.y+1 (hover above the ME interface slot)
        -- and use inspectDown() to identify what is below without landing on it.
        -- If the block below is the ME interface, the chest must be 1 block
        -- closer to the server (serverPos + offset * 1).
        local approachPos = {
            x = serverPos.x + offset.dx * 2,
            y = serverPos.y + 2,
            z = serverPos.z + offset.dz * 2,
        }
        local hoverPos = {
            x = serverPos.x + offset.dx * 2,
            y = serverPos.y + 1,
            z = serverPos.z + offset.dz * 2,
        }

        if moveTo(approachPos) and moveTo(hoverPos) then
            sleep(SCAN_DELAY)

            -- Look down at the ME interface slot
            local downOk, downBlock = turtle.inspectDown()
            if downOk and downBlock and downBlock.name then
                print("  " .. offset.name .. " below: " .. downBlock.name)

                if not blockMatches(downBlock.name, ME_INTERFACE_PATTERNS) then
                    print("  Not an ME interface (got " .. downBlock.name .. "), skipping.")
                else

                -- ME interface confirmed below — chest is 1 block closer to server
                foundChest = {
                    x = serverPos.x + offset.dx,
                    y = serverPos.y,
                    z = serverPos.z + offset.dz,
                }
                foundME = {
                    x = serverPos.x + offset.dx * 2,
                    y = serverPos.y,
                    z = serverPos.z + offset.dz * 2,
                }

                print("FOUND ME interface below, chest inferred at " .. textutils.serialize(foundChest))
                print("ME interface at " .. textutils.serialize(foundME))

                chestPosition       = foundChest
                meInterfacePosition = foundME

                modem.transmit(CHANNEL, CHANNEL, {
                    type = "chest_found",
                    data = {
                        turtleId            = assignedId,
                        chestPosition       = foundChest,
                        meInterfacePosition = foundME,
                    }
                })

                break
                end -- blockMatches ME interface
            else
                print("  " .. offset.name .. ": (nothing below)")
            end
        else
            print("  WARNING: Could not reach hover position for " .. offset.name)
        end
    end

    -- Always go home regardless of outcome
    returnHome()

    if foundChest then
        return true
    else
        print("ERROR: No chest found around server!")
        print("Make sure a chest is placed directly beside the server computer.")
        return false
    end
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
                -- Need to discover it ourselves; make sure we have fuel first.
                print("Discovering chest/ME around server...")
                if not ensureFuel() then
                    print("ERROR: Cannot refuel before chest scan! Add coal to inventory.")
                elseif not findChestAroundServer(msg.data.serverPosition) then
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
                computerId = computerID,
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
