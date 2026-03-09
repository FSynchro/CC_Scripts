-- Thaumcraft Catalyst Pedestal Computer v4.0
-- Monitors the catalyst pedestal for infusion completion.
--
-- State machine:
--   idle    -> infusionExpected=false, armedItem=nil
--              Nothing happening, ignoring pedestal changes.
--
--   waiting -> infusionExpected=true, armedItem=nil
--              Server says an infusion is coming. Watching for the
--              catalyst to be placed on the pedestal.
--
--   armed   -> infusionExpected=true, armedItem=<catalyst item>
--              Catalyst is on the pedestal. Watching for it to mutate
--              into the result item. The infusion is running in Thaumcraft.
--
-- Transitions:
--   idle    -> waiting  : server sends infusion_started
--   waiting -> armed    : pedestal item appears
--   armed   -> idle     : item mutates (fire infusion_complete)
--   armed   -> waiting  : pedestal empties without mutation (item taken back)

local CHANNEL = 1742
local ID_FILE = "altar_id.dat"

local modem         = peripheral.find("modem")
local pedestal      = peripheral.wrap("top")
local altarPosition = nil
local altarId       = nil

local infusionExpected = false   -- server told us an infusion is coming
local armedItem        = nil     -- catalyst item we saw placed; nil = not armed

if not modem    then error("No modem found! Attach an ender modem.") end
if not pedestal then error("No pedestal found above! Place computer below catalyst pedestal.") end

modem.open(CHANNEL)

-- ============================================================
-- PERSISTENCE
-- ============================================================

local function loadSavedId()
    if fs.exists(ID_FILE) then
        local f    = fs.open(ID_FILE, "r")
        local data = textutils.unserialize(f.readAll())
        f.close()
        if data and data.altarId then
            altarId = data.altarId
            print("Loaded saved altar ID: #" .. altarId)
            return true
        end
    end
    return false
end

local function saveId()
    local f = fs.open(ID_FILE, "w")
    f.write(textutils.serialize({ altarId = altarId, altarPosition = altarPosition }))
    f.close()
end

-- ============================================================
-- HELPERS
-- ============================================================

local function getPosition()
    print("Getting GPS position...")
    local x, y, z = gps.locate(5)
    if not x then error("Cannot get GPS position!") end
    return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
end

local function getPedestalItem()
    local item = pedestal.getItemMeta(1)
    if not item then return nil end
    return {
        name        = item.name,
        displayName = item.displayName,
        damage      = item.damage or 0,
        count       = item.count,
        rawName     = item.rawName
    }
end

local function itemsEqual(a, b)
    if a == nil and b == nil then return true end
    if a == nil or b == nil  then return false end
    return a.name == b.name and a.damage == b.damage
end

-- ============================================================
-- REGISTRATION
-- ============================================================

local function registerAltar()
    if altarId then
        print("Re-registering altar #" .. altarId .. "...")
        modem.transmit(CHANNEL, CHANNEL, {
            type = "altar_reregister",
            data = { altarId = altarId, catalystPosition = altarPosition }
        })
    else
        print("Registering altar with server...")
        modem.transmit(CHANNEL, CHANNEL, {
            type = "altar_register",
            data = { catalystPosition = altarPosition }
        })
    end
end

-- ============================================================
-- PEDESTAL MONITOR  (called every second)
-- ============================================================

local function monitorPedestal()
    local current = getPedestalItem()

    if not armedItem then
        -- WAITING state: arm when we see the catalyst appear on the pedestal
        if infusionExpected and current then
            armedItem = current
            print("ARMED: catalyst placed = " .. current.displayName)
        end
    else
        -- ARMED state: watching for Thaumcraft to mutate the catalyst

        if not current then
            -- Pedestal emptied before mutation — item taken back by a turtle or error
            print("Pedestal emptied while armed — disarming, waiting for catalyst again")
            armedItem = nil
            -- infusionExpected stays true: re-arm when catalyst comes back

        elseif not itemsEqual(current, armedItem) then
            -- Item is different — Thaumcraft completed the infusion
            print("INFUSION COMPLETE: " .. armedItem.displayName .. " -> " .. current.displayName)
            modem.transmit(CHANNEL, CHANNEL, {
                type = "infusion_complete",
                data = {
                    altarId    = altarId,
                    resultItem = current,
                    catalyst   = armedItem
                }
            })
            armedItem        = nil
            infusionExpected = false

        end
        -- Item unchanged: infusion still in progress, keep watching
    end
end

-- ============================================================
-- MESSAGE HANDLER
-- ============================================================

local function handleMessage(msg)
    if type(msg) ~= "table" or not msg.type then return end

    if msg.type == "altar_id_assigned" then
        local d = msg.data
        if d.catalystPosition.x == altarPosition.x and
           d.catalystPosition.y == altarPosition.y and
           d.catalystPosition.z == altarPosition.z then
            altarId = d.altarId
            saveId()
            print("")
            print("=================================")
            print("Assigned Altar ID: #" .. altarId)
            print("=================================")
            print("")
        end

    elseif msg.type == "infusion_started" then
        if msg.data.altarId == altarId then
            print("Infusion expected — watching for catalyst to appear...")
            infusionExpected = true
            armedItem        = nil   -- always start fresh; arm on actual observation
        end

    elseif msg.type == "request_pedestal_scan" then
        local d = msg.data
        if d.catalystPosition.x == altarPosition.x and
           d.catalystPosition.y == altarPosition.y and
           d.catalystPosition.z == altarPosition.z then
            print("Pedestal scan requested — waiting for turtle...")
        end
    end
end

-- ============================================================
-- MAIN
-- ============================================================

local function main()
    print("=================================")
    print("Catalyst Pedestal Computer v4.0")
    print("=================================")

    altarPosition = getPosition()
    print("Position: " .. textutils.serialize(altarPosition))

    local hasSavedId = loadSavedId()

    local item = getPedestalItem()
    print("Pedestal: " .. (item and item.displayName or "empty"))

    registerAltar()
    if not hasSavedId then
        print("Waiting for altar ID assignment...")
    end

    local monitorTimer   = os.startTimer(1)
    local registerTimer  = os.startTimer(5)
    local keepaliveTimer = os.startTimer(10)

    while true do
        local event, p1, p2, p3, p4 = os.pullEvent()

        if event == "modem_message" and p2 == CHANNEL then
            handleMessage(p4)

        elseif event == "timer" then
            if p1 == monitorTimer then
                monitorPedestal()
                monitorTimer = os.startTimer(1)

            elseif p1 == registerTimer then
                if not altarId then
                    print("Retrying registration...")
                    registerAltar()
                else
                    modem.transmit(CHANNEL, CHANNEL, {
                        type = "altar_keepalive",
                        data = { altarId = altarId, catalystPosition = altarPosition }
                    })
                end
                registerTimer = os.startTimer(5)

            elseif p1 == keepaliveTimer then
                if altarId then
                    modem.transmit(CHANNEL, CHANNEL, {
                        type = "altar_keepalive",
                        data = { altarId = altarId, catalystPosition = altarPosition }
                    })
                end
                keepaliveTimer = os.startTimer(10)
            end
        end
    end
end

main()
