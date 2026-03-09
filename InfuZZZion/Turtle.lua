-- Thaumcraft Infusion Turtle Worker v4.0
-- Movement unified into a single flyTo(target) function.
-- All operations simply pass a destination; flyTo handles all
-- turning, ascending, horizontal travel and descending.

local CHANNEL        = 1742
local ID_FILE        = "turtle_id.dat"
local SCAN_DELAY     = 0.5
local MOVE_DELAY     = 0.3
local GPS_VERIFY_RETRIES = 3

-- Fuel constants
local MIN_FUEL          = 200
local REFUEL_THRESHOLD  = 100
local REFUEL_SLOT       = 16
local FUEL_ITEMS = {
    ["minecraft:coal"]       = true,
    ["minecraft:charcoal"]   = true,
    ["minecraft:coal_block"] = true,
}

-- ============================================================
-- SECTION 1: LOGGING
-- ============================================================

local logBuffer = {}
local function log(msg)
    local line = "[" .. tostring(math.floor(os.epoch("utc") / 1000)) .. "] " .. tostring(msg)
    table.insert(logBuffer, line)
    print(msg)
    if #logBuffer > 300 then table.remove(logBuffer, 1) end
end

-- Save the general log buffer to a local file.
local function saveLog(label)
    local filename = "log_" .. tostring(label) .. "_" .. tostring(math.floor(os.epoch("utc") / 1000)) .. ".log"
    local f = fs.open(filename, "w")
    if f then
        for _, line in ipairs(logBuffer) do f.writeLine(line) end
        f.close()
        log("Log saved: " .. filename)
    else
        log("ERROR: Could not write log " .. filename)
    end
end

-- ============================================================
-- SECTION 2: STATE
-- ============================================================

local modem = peripheral.find("modem")
if not modem then error("No wireless modem found! Please attach an ender modem.") end
modem.open(CHANNEL)

local homePosition      = nil   -- Where the turtle parks between tasks
local currentPosition   = nil   -- Last known GPS position
local lastGPSCheck      = 0
local GPS_CHECK_INTERVAL = 10   -- Seconds between passive GPS polls

local tasks      = {}
local computerID = os.getComputerID()
local assignedId = nil
local chestPosition        = nil
local meInterfacePosition  = nil

local peerPositions  = {}   -- Other turtles' last broadcast positions
local serverPosition = nil  -- No-fly zone: column above the server computer
local SERVER_CLEAR_Y = nil  -- Must be >= this Y to pass over the server column

-- facing convention: 0=North(-Z)  1=East(+X)  2=South(+Z)  3=West(-X)
local facing = 0

-- ============================================================
-- SECTION 3: FILE I/O
-- ============================================================

local function loadSavedId()
    if fs.exists(ID_FILE) then
        local file = fs.open(ID_FILE, "r")
        local data = textutils.unserialize(file.readAll())
        file.close()
        if data and data.assignedId then
            assignedId = data.assignedId
            facing     = data.facing or 0
            log("Loaded saved turtle ID: #" .. assignedId)
            return true
        end
    end
    return false
end

local function saveId()
    local file = fs.open(ID_FILE, "w")
    file.write(textutils.serialize({ assignedId = assignedId, computerID = computerID, facing = facing }))
    file.close()
end

-- ============================================================
-- SECTION 4: GPS
-- ============================================================

local function getPosition(force)
    local now = os.epoch("utc") / 1000
    if force or not currentPosition or (now - lastGPSCheck) >= GPS_CHECK_INTERVAL then
        for attempt = 1, GPS_VERIFY_RETRIES do
            local x, y, z = gps.locate(5)
            if x then
                currentPosition = { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
                lastGPSCheck = now
                return currentPosition
            end
            if attempt < GPS_VERIFY_RETRIES then
                log("GPS attempt " .. attempt .. " failed, retrying...")
                sleep(0.5)
            end
        end
        if currentPosition then
            log("WARNING: GPS failed, using cached position")
            return currentPosition
        end
        return nil
    end
    return currentPosition
end

-- ============================================================
-- SECTION 5: NETWORKING
-- ============================================================

local function updateStatus(status, detail)
    modem.transmit(CHANNEL, CHANNEL, {
        type = "turtle_status_update",
        data = { turtleId = assignedId, status = status, statusDetail = detail }
    })
end

local function sendKeepalive()
    if assignedId then
        modem.transmit(CHANNEL, CHANNEL, {
            type = "turtle_keepalive",
            data = { turtleId = assignedId, position = currentPosition or homePosition }
        })
    end
end

-- ============================================================
-- SECTION 6: MOVEMENT
--
-- flyTo(target) is the only function that moves the turtle.
--
-- Movement order:
--   1. If target.y > current.y  → ascend FIRST before any horizontal movement
--   2. Move X axis to target.x
--   3. Move Z axis to target.z
--   4. If target.y < current.y  → descend LAST after X and Z are correct
--
-- Obstacle handling (horizontal):
--   If X is blocked  → try up to 5 Z sidesteps to get around it, then retry X
--   If Z is blocked  → try up to 5 X sidesteps to get around it, then retry Z
--   If still blocked → ascend one level and retry horizontal movement
--   After 10 failed attempts → give up, return false
--
-- No-fly zones:
--   serverPosition column: ascend to SERVER_CLEAR_Y before crossing it.
--
-- GPS policy:
--   Always query GPS fresh at the start of flyTo and after every
--   sidestep manoeuvre. Dead-reckon only between normal forward steps;
--   re-sync from GPS every GPS_SYNC_INTERVAL steps.
--
-- Facing convention: 0=North(-Z)  1=East(+X)  2=South(+Z)  3=West(-X)
-- ============================================================

local GPS_SYNC_INTERVAL = 6   -- steps between GPS re-queries mid-flight

-- Derive facing from a GPS before→after delta (used only in calibrateFacing).
local function facingFromMove(before, after)
    local dx = after.x - before.x
    local dz = after.z - before.z
    if dx ==  1 then return 1 end
    if dx == -1 then return 3 end
    if dz ==  1 then return 2 end
    if dz == -1 then return 0 end
    return nil
end

-- Turn to face the given direction (0-3), updating the global `facing`.
local function turnToFace(want)
    local diff = (want - facing) % 4
    if diff == 0 then return end
    if diff == 1 then
        turtle.turnRight(); facing = (facing + 1) % 4; sleep(MOVE_DELAY)
    elseif diff == 3 then
        turtle.turnLeft();  facing = (facing - 1) % 4; sleep(MOVE_DELAY)
    else  -- diff == 2
        turtle.turnRight(); facing = (facing + 1) % 4; sleep(MOVE_DELAY)
        turtle.turnRight(); facing = (facing + 1) % 4; sleep(MOVE_DELAY)
    end
end

-- Calibrate facing by physically moving one block and reading GPS.
local function calibrateFacing()
    local before = getPosition(true)
    if not before then return false end
    local moved = false
    for _ = 1, 4 do
        if turtle.forward() then moved = true; break end
        turtle.turnRight(); facing = (facing + 1) % 4
    end
    if not moved then
        log("WARNING: Cannot calibrate facing (all directions blocked?)")
        return false
    end
    sleep(0.5)
    local after = getPosition(true)
    if after then
        local derived = facingFromMove(before, after)
        if derived then
            facing = derived
            log("Facing calibrated: " .. ({"North","East","South","West"})[facing+1])
        end
    end
    turtle.turnRight(); turtle.turnRight()
    turtle.forward()
    turtle.turnRight(); turtle.turnRight()
    return true
end

-- Save the full movement log to a local file.
local function saveMovementLog(label, lines)
    local filename = "movement_" .. tostring(label) .. "_" .. tostring(math.floor(os.epoch("utc") / 1000)) .. ".log"
    local f = fs.open(filename, "w")
    if f then
        for _, line in ipairs(lines) do f.writeLine(line) end
        f.close()
        log("Movement log saved: " .. filename)
    else
        log("ERROR: Could not write movement log " .. filename)
    end
end

-- flyTo: move the turtle to exactly {x, y, z}.
-- Returns true on GPS-verified arrival, false on failure.
local function flyTo(target)
    if turtle.getFuelLevel() == 0 then
        log("ERROR: Zero fuel, cannot fly!")
        return false
    end

    local pos = getPosition(true)
    if not pos then
        log("ERROR: No GPS fix before flyTo!")
        return false
    end

    -- Per-flyTo movement log — verbose, saved locally on failure
    local mvlog = {}
    local function ml(msg)
        local entry = "[" .. pos.x .. "," .. pos.y .. "," .. pos.z .. "] " .. msg
        table.insert(mvlog, entry)
        log(msg)
    end

    ml("flyTo START target=" .. textutils.serialize(target) .. " facing=" .. facing)

    local stepsSinceGPS = 0
    local attempts      = 0   -- full retry counter (ascend + re-approach)
    local MAX_ATTEMPTS  = 10

    -- ── primitive movement helpers ───────────────────────────────

    local function doStepUp()
        sendKeepalive()
        if turtle.up() then
            pos = { x = pos.x, y = pos.y + 1, z = pos.z }
            stepsSinceGPS = stepsSinceGPS + 1
            sleep(MOVE_DELAY)
            ml("  UP -> " .. pos.y)
            return true
        end
        local ok, blk = turtle.inspectUp()
        ml("  UP blocked: " .. (ok and blk.name or "unknown"))
        turtle.digUp(); sleep(0.2)
        if turtle.up() then
            pos = { x = pos.x, y = pos.y + 1, z = pos.z }
            stepsSinceGPS = stepsSinceGPS + 1
            sleep(MOVE_DELAY)
            ml("  UP (after dig) -> " .. pos.y)
            return true
        end
        return false
    end

    local function doStepDown()
        sendKeepalive()
        if turtle.down() then
            pos = { x = pos.x, y = pos.y - 1, z = pos.z }
            stepsSinceGPS = stepsSinceGPS + 1
            sleep(MOVE_DELAY)
            ml("  DOWN -> " .. pos.y)
            return true
        end
        local ok, blk = turtle.inspectDown()
        ml("  DOWN blocked: " .. (ok and blk.name or "unknown"))
        turtle.digDown(); sleep(0.2)
        if turtle.down() then
            pos = { x = pos.x, y = pos.y - 1, z = pos.z }
            stepsSinceGPS = stepsSinceGPS + 1
            sleep(MOVE_DELAY)
            ml("  DOWN (after dig) -> " .. pos.y)
            return true
        end
        return false
    end

    -- Step forward in wantFacing direction. No digging (avoids other turtles).
    -- Returns true on success, false if blocked.
    local function doStepForward(wantFacing)
        sendKeepalive()
        turnToFace(wantFacing)
        local fnames = {"N","E","S","W"}
        if not turtle.forward() then
            local ok, blk = turtle.inspect()
            ml("  FWD " .. fnames[wantFacing+1] .. " BLOCKED: " .. (ok and blk.name or "unknown"))
            return false
        end
        sleep(MOVE_DELAY)
        stepsSinceGPS = stepsSinceGPS + 1
        local dx = (wantFacing == 1) and 1 or (wantFacing == 3) and -1 or 0
        local dz = (wantFacing == 2) and 1 or (wantFacing == 0) and -1 or 0
        pos = { x = pos.x + dx, y = pos.y, z = pos.z + dz }
        -- Periodic GPS re-sync to keep dead-reckoning honest
        if stepsSinceGPS >= GPS_SYNC_INTERVAL then
            local gps = getPosition(true)
            if gps then
                if gps.x ~= pos.x or gps.z ~= pos.z or gps.y ~= pos.y then
                    ml("  GPS CORRECTION dead=" .. textutils.serialize(pos) .. " gps=" .. textutils.serialize(gps))
                end
                pos = gps
            end
            stepsSinceGPS = 0
        end
        ml("  FWD " .. fnames[wantFacing+1] .. " -> " .. pos.x .. "," .. pos.y .. "," .. pos.z)
        return true
    end

    -- Move along one axis (X or Z) toward target, with sidestep obstacle avoidance.
    -- primaryFacing: direction we want to travel
    -- sideFacingA/B: the two perpendicular directions to try as sidesteps
    -- targetCoord / posCoord: which axis we're working on
    -- Returns true if we made at least one step of progress, false if fully blocked.
    local function driveAxis(primaryFacing, sideFacingA, sideFacingB, getCoord, targetCoord)
        if getCoord(pos) == targetCoord then return true end  -- already correct

        ml("  driveAxis " .. ({"N","E","S","W"})[primaryFacing+1] ..
           " from=" .. getCoord(pos) .. " to=" .. targetCoord)

        -- Try primary direction first
        if doStepForward(primaryFacing) then return true end

        -- Blocked — try sidestep manoeuvres (up to 5 steps each side)
        local sides = {sideFacingA, sideFacingB}
        for _, sideFacing in ipairs(sides) do
            ml("  sidestep attempt via " .. ({"N","E","S","W"})[sideFacing+1])
            local sidesteps = 0
            -- Sidestep up to 5 blocks
            while sidesteps < 5 do
                if not doStepForward(sideFacing) then break end
                sidesteps = sidesteps + 1
                -- After each sidestep, try the primary direction again
                if doStepForward(primaryFacing) then
                    ml("  primary unblocked after " .. sidesteps .. " sidestep(s)")
                    return true
                end
            end
            -- Sidestep didn't help — back up the sidesteps we took
            local reverseFacing = (sideFacing + 2) % 4
            for _ = 1, sidesteps do
                doStepForward(reverseFacing)
            end
            ml("  backed up " .. sidesteps .. " sidestep(s)")
        end

        ml("  driveAxis FAILED on " .. ({"N","E","S","W"})[primaryFacing+1])
        return false
    end

    -- ── main flyTo loop ─────────────────────────────────────────
    while attempts < MAX_ATTEMPTS do

        -- Always GPS-verify at the top of each attempt
        local gps = getPosition(true)
        if gps then pos = gps; stepsSinceGPS = 0 end
        ml("attempt #" .. attempts .. " pos=" .. textutils.serialize(pos) .. " target=" .. textutils.serialize(target))

        -- Arrival check
        if pos.x == target.x and pos.y == target.y and pos.z == target.z then
            ml("ARRIVED at " .. textutils.serialize(pos))
            return true
        end

        local ok = true

        -- Step 1: Ascend if target is above us
        if ok and target.y > pos.y then
            ml("ascending " .. (target.y - pos.y) .. " blocks")
            while pos.y < target.y do
                if not doStepUp() then
                    ml("ERROR: Cannot ascend, bailing attempt")
                    ok = false; break
                end
            end
        end

        -- Step 2: No-fly zone check before horizontal travel
        if ok and serverPosition and SERVER_CLEAR_Y and pos.y < SERVER_CLEAR_Y then
            local crossesServer = (pos.x == serverPosition.x or target.x == serverPosition.x) and
                                  (pos.z == serverPosition.z or target.z == serverPosition.z)
            if crossesServer then
                ml("no-fly zone: ascending to Y=" .. SERVER_CLEAR_Y)
                while pos.y < SERVER_CLEAR_Y do
                    if not doStepUp() then
                        ml("ERROR: Cannot clear no-fly zone")
                        ok = false; break
                    end
                end
            end
        end

        -- Step 3: Move X axis
        if ok and pos.x ~= target.x then
            local xFacing = pos.x < target.x and 1 or 3
            while pos.x ~= target.x do
                if not driveAxis(xFacing, 2, 0,
                    function(p) return p.x end, target.x) then
                    ml("X drive failed, ascending to try again")
                    doStepUp()
                    ok = false; break
                end
                local g = getPosition(true)
                if g then pos = g; stepsSinceGPS = 0 end
            end
        end

        -- Step 4: Move Z axis
        if ok and pos.z ~= target.z then
            local zFacing = pos.z < target.z and 2 or 0
            while pos.z ~= target.z do
                if not driveAxis(zFacing, 1, 3,
                    function(p) return p.z end, target.z) then
                    ml("Z drive failed, ascending to try again")
                    doStepUp()
                    ok = false; break
                end
                local g = getPosition(true)
                if g then pos = g; stepsSinceGPS = 0 end
            end
        end

        -- Step 5: Descend if target is below us (only after X and Z are correct)
        if ok and target.y < pos.y then
            ml("descending " .. (pos.y - target.y) .. " blocks")
            while pos.y > target.y do
                if not doStepDown() then
                    ml("ERROR: Cannot descend, bailing attempt")
                    ok = false; break
                end
            end
        end

        -- Final GPS verify
        if ok then
            local final = getPosition(true)
            if final then pos = final end
            if pos.x == target.x and pos.y == target.y and pos.z == target.z then
                ml("ARRIVED (verified) at " .. textutils.serialize(pos))
                return true
            else
                ml("Post-move GPS mismatch: pos=" .. textutils.serialize(pos) .. " target=" .. textutils.serialize(target))
            end
        end

        attempts = attempts + 1
    end

    -- All attempts exhausted — save local log and fail
    ml("FAILED after " .. MAX_ATTEMPTS .. " attempts")
    saveMovementLog("flyTo_fail", mvlog)
    return false
end

-- ============================================================
-- SECTION 7: FUEL
-- ============================================================

local function isFuelItem(name)
    return name and FUEL_ITEMS[name] == true
end

local function findFuelInChest(chest)
    if not chest or not chest.list then return false end
    for slot, item in pairs(chest.list()) do
        if isFuelItem(item.name) then
            local ok, moved = pcall(function()
                return chest.pushItems(peripheral.getName(turtle) or "turtle", slot, 64, REFUEL_SLOT)
            end)
            if ok and moved and moved > 0 then
                log("Pulled " .. moved .. "x " .. item.name .. " via pushItems")
                return true
            end
            break
        end
    end
    turtle.select(REFUEL_SLOT)
    if turtle.suckDown(64) then
        local sucked = turtle.getItemDetail(REFUEL_SLOT)
        if sucked and isFuelItem(sucked.name) then
            log("Pulled fuel via suckDown: " .. sucked.name)
            turtle.select(1)
            return true
        else
            if sucked then log("ERROR: suckDown got wrong item: " .. sucked.name .. ". Returning.") end
            turtle.dropDown(turtle.getItemCount(REFUEL_SLOT))
            turtle.select(1)
            return false
        end
    end
    turtle.select(1)
    return false
end

local function refuelFromSlot()
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and isFuelItem(detail.name) then
            turtle.select(slot)
            turtle.refuel()
            log("Refuelled from slot " .. slot .. "! Fuel now: " .. turtle.getFuelLevel())
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
    log("Checking inventory for fuel...")
    if refuelFromSlot() then
        log("Refuelled from inventory! Fuel: " .. turtle.getFuelLevel())
        updateStatus("idle", "refuelled")
        return true
    end

    local refuelPos = meInterfacePosition
    if not refuelPos then
        log("ERROR: ME interface position unknown, cannot refuel!")
        return false
    end
    if turtle.getFuelLevel() == 0 then
        log("CRITICAL: Zero fuel and no coal in inventory!")
        return false
    end

    log("Heading to ME interface for fuel...")
    updateStatus("refuelling", "going to ME interface")

    -- Fly to one block above the ME interface, then suck from below
    if not flyTo({ x = refuelPos.x, y = refuelPos.y + 1, z = refuelPos.z }) then
        log("ERROR: Cannot reach ME interface!")
        return false
    end

    local me = peripheral.wrap("bottom")
    if not me or not me.list then
        log("ERROR: No ME interface below refuel position!")
        return false
    end
    if not findFuelInChest(me) then
        log("ERROR: No fuel in ME interface!")
        return false
    end

    local ok = refuelFromSlot()
    if ok then
        log("Refuel complete! Fuel: " .. turtle.getFuelLevel())
        updateStatus("idle", "refuelled")
    else
        log("WARNING: Still low after refuel: " .. turtle.getFuelLevel())
    end
    return ok
end

local function ensureFuel()
    if turtle.getFuelLevel() >= MIN_FUEL then return true end
    return doRefuel()
end

-- ============================================================
-- SECTION 8: RETURN HOME
-- ============================================================

-- returnItemsToChest is forward-declared here so returnHome can call it.
local returnItemsToChest

local function returnHome()
    if not homePosition then return false end
    log("Returning home...")
    updateStatus("returning", "going home")

    if not flyTo(homePosition) then
        local cur = getPosition(true)
        log("ERROR: Cannot reach home! cur=" .. textutils.serialize(cur))
        saveLog("home_fail")
        return false
    end

    log("Home!")
    saveId()

    -- Deposit any stray non-fuel items
    if chestPosition then
        local hasStray = false
        for slot = 1, 16 do
            local d = turtle.getItemDetail(slot)
            if d and not isFuelItem(d.name) then hasStray = true; break end
        end
        if hasStray then
            log("Found stray items, returning to chest...")
            returnItemsToChest(chestPosition)
            -- flyTo home again after deposit
            flyTo(homePosition)
            log("Home again after returning items!")
        end
    end

    updateStatus("idle", "waiting")
    sendKeepalive()
    return true
end

-- ============================================================
-- SECTION 9: BLOCK INSPECTION HELPERS
-- ============================================================

local CHEST_PATTERNS        = {"chest"}
local PEDESTAL_PATTERNS     = {"pedestal"}
local STABILIZER_PATTERNS   = {"skull", "head", "candle"}
local ME_INTERFACE_PATTERNS = {"me_interface", "interface", "appeng", "ae2"}

local function blockMatches(blockName, patterns)
    if not blockName then return false end
    local lower = blockName:lower()
    for _, p in ipairs(patterns) do
        if lower:find(p:lower()) then return true end
    end
    return false
end

-- Move to one block above targetPos and inspect down.
-- Callers pass the actual block position; we handle the +1 internally.
local function inspectBelow(targetPos)
    local abovePos = { x = targetPos.x, y = targetPos.y + 1, z = targetPos.z }
    if not flyTo(abovePos) then
        log("  inspectBelow: could not reach above " .. textutils.serialize(targetPos))
        return false, nil
    end
    sleep(SCAN_DELAY)
    local success, block = turtle.inspectDown()
    if success and block and block.name then
        log("  inspectBelow " .. textutils.serialize(targetPos) .. " => " .. block.name)
        return true, block
    end
    log("  inspectBelow " .. textutils.serialize(targetPos) .. " => (nothing)")
    return true, nil
end

-- ============================================================
-- SECTION 10: SCANNING
-- ============================================================

local function isStabilizer(name) return blockMatches(name, STABILIZER_PATTERNS) end

local function scanPedestalsAroundCatalyst(catalystPos, assignedRows)
    log("=================================")
    log("STARTING PEDESTAL SCAN")
    log("Catalyst: " .. textutils.serialize(catalystPos))
    log("Rows (Z): " .. textutils.serialize(assignedRows))
    log("Fuel: " .. turtle.getFuelLevel())
    log("=================================")

    updateStatus("scanning", "scanning pedestals")
    sendKeepalive()

    local pedestals         = {}
    local stabilizers       = {}
    local foundPedestals    = {}
    local foundStabilizers  = {}

    for rowIdx, zOffset in ipairs(assignedRows) do
        log("Row " .. rowIdx .. "/" .. #assignedRows .. " (Z=" .. zOffset .. ")...")

        for xOffset = -3, 3 do
            if not (xOffset == 0 and zOffset == 0) then

                if turtle.getFuelLevel() < REFUEL_THRESHOLD then
                    log("Fuel low during scan (" .. turtle.getFuelLevel() .. "), refuelling...")
                    if not doRefuel() then log("WARNING: Could not refuel during scan, continuing") end
                end

                -- Fresh GPS fix before each cell so flyTo starts from a known-good
                -- position and mid-travel syncs don't cause axis re-shuffling.
                getPosition(true)

                -- flyTo handles the transit height automatically (ascend before moving horizontally).
                -- We scan from two blocks above the pedestal surface.
                local scanPos = {
                    x = catalystPos.x + xOffset,
                    y = catalystPos.y + 2,   -- two above surface so turtle clears pedestal tops
                    z = catalystPos.z + zOffset
                }

                local reached = flyTo(scanPos)
                local block   = nil
                if reached then
                    sleep(SCAN_DELAY)
                    local ok, b = turtle.inspectDown()
                    if ok and b and b.name then block = b end
                end

                if not reached then
                    log("  WARNING: Could not reach [" .. xOffset .. "," .. zOffset .. "], continuing scan")
                elseif block then
                    -- Pedestal is 1 below scan height (turtle at catalystPos.y+2, pedestal at catalystPos.y+1)
                    local pedestalPos = {
                        x = scanPos.x,
                        y = scanPos.y - 1,
                        z = scanPos.z
                    }
                    local posKey = pedestalPos.x .. "," .. pedestalPos.y .. "," .. pedestalPos.z

                    if blockMatches(block.name, PEDESTAL_PATTERNS) then
                        if not foundPedestals[posKey] then
                            foundPedestals[posKey] = true
                            table.insert(pedestals, pedestalPos)
                            log("  PEDESTAL at [" .. xOffset .. "," .. zOffset .. "]")
                        end
                    elseif blockMatches(block.name, STABILIZER_PATTERNS) then
                        if not foundStabilizers[posKey] then
                            foundStabilizers[posKey] = true
                            table.insert(stabilizers, pedestalPos)
                            log("  STABILIZER at [" .. xOffset .. "," .. zOffset .. "]")
                        end
                    end
                end

                sendKeepalive()
            end
        end

        log("End of row " .. rowIdx .. " | Pedestals: " .. #pedestals .. " Stabilizers: " .. #stabilizers)
    end

    log("=================================")
    log("SCAN COMPLETE — Pedestals: " .. #pedestals .. " Stabilizers: " .. #stabilizers)
    log("=================================")

    return pedestals, stabilizers
end

-- ============================================================
-- SECTION 11: ITEM HANDLING
--
-- All item operations follow the same "operate from above" pattern:
--   flyTo({x, blockY+1, z}) → act on what's below (suck/drop/inspect)
--
-- This means:
--   pickupItemFromChest  → flyTo chest+1, suckDown
--   returnItemsToChest   → flyTo chest+1, dropDown
--   placeItemOnPedestal  → flyTo pedestal+1, dropDown
--   retrieveItemFromPedestal → flyTo pedestal+1, suckDown
--   clearPedestal        → flyTo pedestal+1, suckDown
--
-- flyTo's ascend-first ordering ensures the turtle always rises to
-- clear any horizontal obstacles before moving sideways.
-- ============================================================

local function pickupItemFromChest(item, chestPos)
    -- Fly to one block above the chest
    if not flyTo({ x = chestPos.x, y = chestPos.y + 1, z = chestPos.z }) then
        log("ERROR: Cannot reach chest at " .. textutils.serialize(chestPos))
        return false
    end

    local chest = peripheral.wrap("bottom")
    if not chest or not chest.list then
        log("ERROR: No chest found below at " .. textutils.serialize(chestPos))
        return false
    end

    -- Find the correct slot
    local itemSlot = nil
    for slot, chestItem in pairs(chest.list()) do
        if chestItem.name == item.item.name then
            local match = true
            if item.matchDMG and (chestItem.damage or 0) ~= (item.item.damage or 0) then
                match = false
            end
            if match then itemSlot = slot; break end
        end
    end

    if not itemSlot then
        log("ERROR: Item not found in chest: " .. item.item.name)
        return false
    end

    turtle.select(1)

    -- Preferred: pushItems (precise slot targeting)
    local ok, moved = pcall(function()
        return chest.pushItems(peripheral.getName(turtle) or "turtle", itemSlot, 1, 1)
    end)
    if ok and moved and moved > 0 then
        log("Picked up " .. item.item.name .. " via pushItems")
        return true
    end

    -- Fallback: suckDown
    if not turtle.suckDown(1) then
        log("ERROR: Cannot suck item from chest")
        return false
    end
    local pickedUp = turtle.getItemDetail(1)
    if pickedUp then
        if isFuelItem(pickedUp.name) then
            log("WARNING: suckDown grabbed fuel " .. pickedUp.name .. ", returning")
            turtle.dropDown(turtle.getItemCount(1))
            return false
        end
        log("Picked up " .. pickedUp.name .. " (wanted " .. item.item.name .. ")")
    end
    return true
end

-- defined via forward reference so returnHome can call it
returnItemsToChest = function(chestPos)
    local hasItems = false
    for slot = 1, 16 do
        local d = turtle.getItemDetail(slot)
        if d and not isFuelItem(d.name) then hasItems = true; break end
    end
    if not hasItems then return end

    log("Returning stray items to chest...")

    if not flyTo({ x = chestPos.x, y = chestPos.y + 1, z = chestPos.z }) then
        log("ERROR: Could not reach chest to return items!")
        return
    end

    for slot = 1, 16 do
        local d = turtle.getItemDetail(slot)
        if d and not isFuelItem(d.name) then
            turtle.select(slot)
            turtle.dropDown(turtle.getItemCount(slot))
            log("Returned " .. d.name .. " from slot " .. slot)
        end
    end
    turtle.select(1)
end

local function placeItemOnPedestal(item, pedestalPos, chestPos)
    log("Placing " .. item.item.name .. " on pedestal at " .. textutils.serialize(pedestalPos))
    updateStatus("working", "picking up item")

    if not pickupItemFromChest(item, chestPos) then
        return false
    end

    updateStatus("working", "placing on pedestal")

    -- Fly to one block above the pedestal, then drop down onto it
    if not flyTo({ x = pedestalPos.x, y = pedestalPos.y + 1, z = pedestalPos.z }) then
        log("ERROR: Cannot reach above pedestal, returning item")
        returnItemsToChest(chestPos)
        return false
    end

    turtle.select(1)
    if not turtle.dropDown(1) then
        log("ERROR: Cannot drop onto pedestal, returning item")
        returnItemsToChest(chestPos)
        return false
    end

    log("Item placed on pedestal!")
    return true
end

local function retrieveItemFromPedestal(pedestalPos, mePos)
    log("Retrieving item from pedestal at " .. textutils.serialize(pedestalPos))
    updateStatus("working", "picking up result")

    if not flyTo({ x = pedestalPos.x, y = pedestalPos.y + 1, z = pedestalPos.z }) then
        log("ERROR: Cannot reach pedestal for retrieval")
        return false
    end

    turtle.select(1)
    if not turtle.suckDown(1) then
        log("ERROR: Cannot suck item from pedestal")
        return false
    end

    updateStatus("working", "depositing to ME")

    if not flyTo({ x = mePos.x, y = mePos.y + 1, z = mePos.z }) then
        log("ERROR: Cannot reach ME interface for deposit")
        return false
    end

    turtle.select(1)
    if not turtle.dropDown(1) then
        log("ERROR: Cannot drop into ME interface")
        return false
    end

    log("Result deposited to ME!")
    return true
end

local function clearPedestal(pedestalPos, mePos)
    log("Clearing pedestal at " .. textutils.serialize(pedestalPos))
    updateStatus("working", "clearing pedestal")

    if not flyTo({ x = pedestalPos.x, y = pedestalPos.y + 1, z = pedestalPos.z }) then
        log("ERROR: Cannot reach pedestal to clear")
        return false
    end

    turtle.select(1)
    if turtle.suckDown(1) then
        if not flyTo({ x = mePos.x, y = mePos.y + 1, z = mePos.z }) then
            log("ERROR: Cannot reach ME interface after clearing pedestal")
            return false
        end
        turtle.select(1)
        turtle.dropDown(1)
        log("Pedestal cleared, item deposited")
    else
        log("Pedestal already empty")
    end

    return true
end

-- ============================================================
-- SECTION 12: CHEST/ME DISCOVERY
-- ============================================================

local CARDINAL_OFFSETS = {
    {dx =  0, dz = -1, name = "North", face = 0},
    {dx =  1, dz =  0, name = "East",  face = 1},
    {dx =  0, dz =  1, name = "South", face = 2},
    {dx = -1, dz =  0, name = "West",  face = 3},
}

local function findChestAroundServer(serverPos)
    log("=================================")
    log("SEARCHING FOR CHEST/ME INTERFACE")
    log("Server pos: " .. textutils.serialize(serverPos))
    log("=================================")

    updateStatus("searching", "finding chest")

    local foundChest = nil
    local foundME    = nil

    for _, offset in ipairs(CARDINAL_OFFSETS) do
        log("Checking " .. offset.name .. " side...")

        -- Hover one block above and two blocks out from the server.
        -- flyTo ascends to clear the server before moving horizontally.
        local hoverPos = {
            x = serverPos.x + offset.dx * 2,
            y = serverPos.y + 1,
            z = serverPos.z + offset.dz * 2,
        }

        if flyTo(hoverPos) then
            sleep(SCAN_DELAY)
            local downOk, downBlock = turtle.inspectDown()
            if downOk and downBlock and downBlock.name then
                log("  " .. offset.name .. " below: " .. downBlock.name)

                if not blockMatches(downBlock.name, ME_INTERFACE_PATTERNS) then
                    log("  Not an ME interface (got " .. downBlock.name .. "), skipping.")
                else
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

                    log("FOUND ME interface! Chest inferred at " .. textutils.serialize(foundChest))
                    log("ME interface at " .. textutils.serialize(foundME))

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
                end
            else
                log("  " .. offset.name .. ": (nothing below)")
            end
        else
            log("  WARNING: Could not reach hover position for " .. offset.name)
        end
    end

    returnHome()

    if foundChest then
        return true
    else
        log("ERROR: No chest found! Make sure a chest is placed beside the server.")
        return false
    end
end

-- ============================================================
-- SECTION 13: TASK EXECUTION
-- ============================================================

local function executeTask(task)
    log("Executing task: " .. task.type)

    if not ensureFuel() then
        log("ERROR: Cannot get fuel for task!")
        return false
    end

    if task.type == "scan_pedestals" then
        local pedestals, stabilizers = scanPedestalsAroundCatalyst(task.catalystPosition, task.assignedRows)

        modem.transmit(CHANNEL, CHANNEL, {
            type = "pedestals_scanned",
            data = {
                altarId             = task.altarId,
                pedestalPositions   = pedestals,
                stabilizerPositions = stabilizers,
                turtleId            = assignedId
            }
        })
        return returnHome()

    elseif task.type == "place_catalyst" then
        updateStatus("working", "placing catalyst")
        local cp = task.chestPosition or chestPosition
        if not cp then log("ERROR: No chest position for place_catalyst!") return false end
        local result = placeItemOnPedestal(task.item, task.position, cp)
        returnHome()
        return result

    elseif task.type == "place_ingredient" then
        updateStatus("working", "placing ingredient")
        local cp = task.chestPosition or chestPosition
        if not cp then log("ERROR: No chest position for place_ingredient!") return false end
        local result = placeItemOnPedestal(task.item, task.position, cp)
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
            data = { turtleId = assignedId, success = success }
        })
    end
    updateStatus("idle", "waiting")
    sendKeepalive()
    log("Tasks complete")
end

-- ============================================================
-- SECTION 14: MESSAGE HANDLING
-- ============================================================

local function handleMessage(msg)
    if type(msg) ~= "table" or not msg.type then return end

    if msg.type == "turtle_id_assigned" then
        if msg.data.computerId == computerID then
            assignedId = msg.data.assignedId
            saveId()

            log("")
            log("=================================")
            log("Assigned ID: #" .. assignedId)
            log("Fuel: " .. turtle.getFuelLevel())
            log("=================================")

            if msg.data.serverPosition then
                serverPosition = msg.data.serverPosition
                SERVER_CLEAR_Y = serverPosition.y + 2
                log("Server no-fly zone set at " .. textutils.serialize(serverPosition))
            end

            if msg.data.chestPosition then
                chestPosition       = msg.data.chestPosition
                meInterfacePosition = msg.data.meInterfacePosition
                if not serverPosition and chestPosition then
                    SERVER_CLEAR_Y = chestPosition.y + 2
                end
                log("Chest pos from server: " .. textutils.serialize(chestPosition))
                log("ME pos from server:    " .. textutils.serialize(meInterfacePosition))
            elseif msg.data.serverPosition then
                log("Discovering chest/ME around server...")
                if not ensureFuel() then
                    log("ERROR: Cannot refuel before chest scan!")
                elseif not findChestAroundServer(msg.data.serverPosition) then
                    log("ERROR: Could not find chest!")
                end
            else
                log("WARNING: No server position provided, chest location unknown.")
            end

            if turtle.getFuelLevel() < MIN_FUEL then
                log("Fuel below minimum, refuelling now...")
                doRefuel()
            end
        end

    elseif msg.type == "scan_pedestals" then
        if msg.data.turtleId == assignedId then
            log("Received scan task for altar #" .. msg.data.altarId)
            tasks = {{
                type             = "scan_pedestals",
                altarId          = msg.data.altarId,
                catalystPosition = msg.data.catalystPosition,
                assignedRows     = msg.data.assignedRows
            }}
            processTasks()
        end

    elseif msg.type == "turtle_tasks" then
        if msg.data.turtleId == assignedId then
            tasks = msg.data.tasks
            local delay = msg.data.startDelay or 0
            if delay > 0 then
                log("Waiting " .. (delay * 0.05) .. "s before starting tasks...")
                sleep(delay * 0.05)
            end
            processTasks()
        end

    elseif msg.type == "turtle_keepalive" then
        local d = msg.data
        if d and d.turtleId and d.turtleId ~= assignedId and d.position then
            peerPositions[d.turtleId] = {
                x = d.position.x, y = d.position.y, z = d.position.z,
                time = os.epoch("utc")
            }
        end

    elseif msg.type == "abort_and_return" then
        if msg.data.turtleId == assignedId then
            log("ABORT AND RETURN")
            tasks = {}
            updateStatus("returning", "aborting infusion")
            if chestPosition then returnItemsToChest(chestPosition) end
            returnHome()
        end

    elseif msg.type == "disaster_abort" then
        log("DISASTER ABORT!")
        tasks = {}
        updateStatus("idle", "aborted")
        returnHome()
    end
end

-- ============================================================
-- SECTION 15: MAIN LOOP
-- ============================================================

local function main()
    log("=================================")
    log("Thaumcraft Turtle Worker v4.0")
    log("=================================")
    log("Computer ID: " .. computerID)
    log("Fuel:        " .. turtle.getFuelLevel())
    log("REFUEL_SLOT: " .. REFUEL_SLOT .. " (keep empty or coal only)")
    log("=================================")

    if turtle.getFuelLevel() < 10 then
        log("WARNING: Very low fuel! Add coal to slot " .. REFUEL_SLOT)
    end

    local hasSavedId = loadSavedId()

    homePosition = getPosition(true)
    if not homePosition then error("ERROR: Cannot get GPS position!") end
    log("Home: " .. textutils.serialize(homePosition))

    calibrateFacing()

    if hasSavedId then
        log("Re-registering with ID #" .. assignedId)
        modem.transmit(CHANNEL, CHANNEL, {
            type = "turtle_reregister",
            data = { turtleId = assignedId, computerId = computerID, position = homePosition }
        })
    else
        log("Registering as new turtle")
        modem.transmit(CHANNEL, CHANNEL, {
            type = "turtle_register",
            data = { computerId = computerID, position = homePosition }
        })
    end

    log("Waiting for server...")

    local registerTimer  = os.startTimer(5)
    local keepaliveTimer = os.startTimer(30)

    while true do
        local event, side, channel, _, message = os.pullEvent()

        if event == "modem_message" and channel == CHANNEL then
            handleMessage(message)

        elseif event == "timer" then
            if side == registerTimer then
                if not assignedId then
                    modem.transmit(CHANNEL, CHANNEL, {
                        type = "turtle_register",
                        data = { computerId = computerID, position = homePosition }
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
