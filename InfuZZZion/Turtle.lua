-- Thaumcraft Infusion Turtle Worker v4.0
-- Movement unified into a single flyTo(target) function.
-- All operations simply pass a destination; flyTo handles all
-- turning, ascending, horizontal travel and descending.

local CHANNEL        = 1742
local ID_FILE        = "turtle_id.dat"
local PASTEBIN_KEY   = "4H0FPE9BW0Yf1FT_GkPygjlmIREfylxd"  -- get free key at pastebin.com/doc/api
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

local function uploadLog(label)
    if not http then log("HTTP not available, cannot upload log") return nil end
    local body = "=== Turtle Log: " .. tostring(label) .. " ===\n" .. table.concat(logBuffer, "\n")
    local ok, err = pcall(function()
        local resp = http.post("https://pastebin.com/api/api_post.php",
            "api_dev_key=" .. PASTEBIN_KEY ..
            "&api_option=paste" ..
            "&api_paste_code=" .. textutils.urlEncode(body) ..
            "&api_paste_name=" .. textutils.urlEncode("Turtle#" .. tostring(assignedId) .. "_" .. tostring(label)) ..
            "&api_paste_expire_date=1H"
        )
        if resp then
            local url = resp.readAll()
            resp.close()
            log("Log uploaded: " .. tostring(url))
        end
    end)
    if not ok then log("Upload failed: " .. tostring(err)) end
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
-- SECTION 6: MOVEMENT  (the single source of motion truth)
--
-- Design:
--   flyTo(target)  — the only function that moves the turtle.
--
--   Order of axes:  ascend → X → Z → descend
--   This means the turtle always clears whatever is at its current
--   height before moving horizontally, and only descends once it is
--   directly above the destination column.
--
--   No caller ever calls turtle.up/down/forward directly.
--   No caller pre-ascends or post-descends outside flyTo.
--   Callers that need to operate "from above" (inspect, pick up, drop)
--   simply pass  {x, targetY+1, z}  as their destination.
--
-- No-fly zones:
--   • serverPosition column: ascend to SERVER_CLEAR_Y before crossing it.
--
-- GPS policy:
--   Dead-reckon between moves; re-sync from GPS every GPS_SYNC_INTERVAL
--   steps.  On arrival, always do a final GPS verify.
--
-- Facing convention: 0=North(-Z)  1=East(+X)  2=South(+Z)  3=West(-X)
-- ============================================================

local GPS_SYNC_INTERVAL = 8   -- steps between GPS re-queries mid-flight
local MAX_IDLE          = 16  -- bail if Manhattan distance doesn't shrink for this many iterations

-- Derive the facing we actually had from a before→after GPS delta.
local function facingFromMove(before, after)
    local dx = after.x - before.x
    local dz = after.z - before.z
    if dx ==  1 then return 1 end  -- East
    if dx == -1 then return 3 end  -- West
    if dz ==  1 then return 2 end  -- South
    if dz == -1 then return 0 end  -- North
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
    else  -- diff == 2: 180°
        turtle.turnRight(); facing = (facing + 1) % 4; sleep(MOVE_DELAY)
        turtle.turnRight(); facing = (facing + 1) % 4; sleep(MOVE_DELAY)
    end
end

-- Calibrate facing by physically moving one block and reading GPS.
-- Called once at startup, after homePosition is known.
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

    -- Step back
    turtle.turnRight(); turtle.turnRight()
    turtle.forward()
    turtle.turnRight(); turtle.turnRight()
    return true
end

-- flyTo: move the turtle to exactly {x,y,z}.
-- Returns true on successful GPS-verified arrival, false on failure.
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

    log("flyTo " .. textutils.serialize(target))

    local idleCount     = 0
    local stepsSinceGPS = 0
    -- Per-axis stuck counters — never reset by progress on a different axis.
    local stuckY   = 0
    local stuckX   = 0
    local stuckZ   = 0
    local STUCK_UPLOAD = 3   -- upload log after this many consecutive failures on one axis
    local lastDist = math.abs(target.x - pos.x)
                   + math.abs(target.y - pos.y)
                   + math.abs(target.z - pos.z)

    -- ── helpers used only inside the loop ──────────────────────

    -- Try to step up one block; digs solid (non-turtle) obstacles.
    local function stepUp()
        sendKeepalive()
        if turtle.up() then
            pos = { x = pos.x, y = pos.y + 1, z = pos.z }
            stepsSinceGPS = stepsSinceGPS + 1
            sleep(MOVE_DELAY)
            return true
        end
        -- Something overhead — dig it and retry
        local ok, blk = turtle.inspectUp()
        if ok then log("  dig up: " .. blk.name) end
        turtle.digUp()
        sleep(0.2)
        if turtle.up() then
            pos = { x = pos.x, y = pos.y + 1, z = pos.z }
            stepsSinceGPS = stepsSinceGPS + 1
            sleep(MOVE_DELAY)
            return true
        end
        return false
    end

    -- Try to step down one block; digs solid obstacles below.
    local function stepDown()
        sendKeepalive()
        if turtle.down() then
            pos = { x = pos.x, y = pos.y - 1, z = pos.z }
            stepsSinceGPS = stepsSinceGPS + 1
            sleep(MOVE_DELAY)
            return true
        end
        local ok, blk = turtle.inspectDown()
        if ok then log("  dig down: " .. blk.name) end
        turtle.digDown()
        sleep(0.2)
        if turtle.down() then
            pos = { x = pos.x, y = pos.y - 1, z = pos.z }
            stepsSinceGPS = stepsSinceGPS + 1
            sleep(MOVE_DELAY)
            return true
        end
        return false
    end

    -- Try to step forward one block (no digging — avoids hitting other turtles).
    -- Updates pos and re-derives facing from GPS delta.
    local function stepForward(wantFacing)
        sendKeepalive()
        turnToFace(wantFacing)
        local before = pos
        if not turtle.forward() then
            local ok, blk = turtle.inspect()
            log("  forward blocked (facing=" .. wantFacing .. "): " .. (ok and blk.name or "air/unknown"))
            return false
        end
        sleep(MOVE_DELAY)
        stepsSinceGPS = stepsSinceGPS + 1
        -- Dead-reckon new position
        local dx = (wantFacing == 1) and 1 or (wantFacing == 3) and -1 or 0
        local dz = (wantFacing == 2) and 1 or (wantFacing == 0) and -1 or 0
        pos = { x = pos.x + dx, y = pos.y, z = pos.z + dz }
        -- Re-derive facing from actual GPS delta once we re-sync
        local derived = facingFromMove(before, pos)
        if derived then facing = derived end
        return true
    end

    -- ── main navigation loop ────────────────────────────────────
    while true do

        -- Periodic GPS re-sync (or on potential arrival)
        if stepsSinceGPS >= GPS_SYNC_INTERVAL or
           (pos.x == target.x and pos.y == target.y and pos.z == target.z) then
            local gpsPos = getPosition(true)
            if gpsPos then pos = gpsPos end
            stepsSinceGPS = 0
        end

        -- Arrival check
        if pos.x == target.x and pos.y == target.y and pos.z == target.z then
            -- Final GPS verification
            local verified = getPosition(true)
            if verified and verified.x == target.x and verified.y == target.y and verified.z == target.z then
                return true
            elseif verified then
                pos = verified  -- not quite there — continue loop
            end
        end

        -- Progress check (bail if stuck)
        local dist = math.abs(target.x - pos.x)
                   + math.abs(target.y - pos.y)
                   + math.abs(target.z - pos.z)
        if dist < lastDist then
            idleCount = 0; lastDist = dist
        else
            idleCount = idleCount + 1
            if idleCount >= MAX_IDLE then
                log("ERROR: flyTo stuck! target=" .. textutils.serialize(target) .. " pos=" .. textutils.serialize(pos))
                uploadLog("stuck")
                return false
            end
        end

        -- ── Axis decision ──────────────────────────────────────
        -- Priority: ascend → X (with no-fly guard) → Z (with no-fly guard) → descend

        if pos.y < target.y then
            if not stepUp() then
                stuckY = stuckY + 1
                if stuckY >= 5 then
                    log("ERROR: Cannot ascend to target Y!")
                    uploadLog("stuck_up")
                    return false
                end
            else
                stuckY = 0
            end

        elseif pos.x ~= target.x then
            local nextX = pos.x + (pos.x < target.x and 1 or -1)
            if serverPosition and SERVER_CLEAR_Y
               and nextX == serverPosition.x and pos.z == serverPosition.z
               and pos.y < SERVER_CLEAR_Y then
                log("No-fly ahead on X, ascending to Y=" .. SERVER_CLEAR_Y)
                if not stepUp() then
                    stuckY = stuckY + 1
                    if stuckY >= 5 then log("ERROR: Stuck ascending for no-fly X!") return false end
                else stuckY = 0 end
            else
                local wantFacing = pos.x < target.x and 1 or 3
                if stepForward(wantFacing) then
                    stuckX = 0
                else
                    stuckX = stuckX + 1
                    log("X stuck x" .. stuckX .. " (facing=" .. wantFacing .. " pos=" .. textutils.serialize(pos) .. " target=" .. textutils.serialize(target) .. ")")
                    if stuckX >= STUCK_UPLOAD then
                        uploadLog("stuck_X")
                    end
                    if stuckX >= 5 then
                        log("ERROR: Stuck on X axis!")
                        return false
                    end
                end
            end

        elseif pos.z ~= target.z then
            local nextZ = pos.z + (pos.z < target.z and 1 or -1)
            if serverPosition and SERVER_CLEAR_Y
               and pos.x == serverPosition.x and nextZ == serverPosition.z
               and pos.y < SERVER_CLEAR_Y then
                log("No-fly ahead on Z, ascending to Y=" .. SERVER_CLEAR_Y)
                if not stepUp() then
                    stuckY = stuckY + 1
                    if stuckY >= 5 then log("ERROR: Stuck ascending for no-fly Z!") return false end
                else stuckY = 0 end
            else
                local wantFacing = pos.z < target.z and 2 or 0
                if stepForward(wantFacing) then
                    stuckZ = 0
                else
                    stuckZ = stuckZ + 1
                    log("Z stuck x" .. stuckZ .. " (facing=" .. wantFacing .. " pos=" .. textutils.serialize(pos) .. " target=" .. textutils.serialize(target) .. ")")
                    if stuckZ >= STUCK_UPLOAD then
                        uploadLog("stuck_Z")
                    end
                    if stuckZ >= 5 then
                        log("ERROR: Stuck on Z axis!")
                        return false
                    end
                end
            end

        elseif pos.y > target.y then
            if not stepDown() then
                stuckY = stuckY + 1
                if stuckY >= 5 then
                    log("ERROR: Cannot descend to target Y!")
                    uploadLog("stuck_down")
                    return false
                end
            else
                stuckY = 0
            end
        end

        sendKeepalive()
    end
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
        uploadLog("home_fail")
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
                    -- The pedestal itself is one block below our scan position
                    local pedestalPos = {
                        x = scanPos.x,
                        y = scanPos.y - 1,   -- one below scan height = pedestal surface
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
