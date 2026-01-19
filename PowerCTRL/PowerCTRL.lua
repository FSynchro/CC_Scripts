-- =================================================================
-- Configuration & State
-- =================================================================
local refreshRate = 1
local autoMode = true
local lastTotalEnergy = 0
local energyFlow = "Stable"

-- =================================================================
-- Utility Logic
-- =================================================================
local function scrubToNum(val)
    if type(val) == "number" then return val end
    if type(val) == "string" then
        local cleaned = val:gsub("[^%d%.%-]", "")
        return tonumber(cleaned) or 0
    end
    if type(val) == "table" then return val.amount or val.energy or 0 end
    return 0
end

-- Linear Mapping: Maps storage % to Rod Insertion %
-- 80% storage -> 100% rods
-- 20% storage -> 10% rods
local function calculateRodTarget(storagePercent)
    if storagePercent >= 0.80 then return 100 end
    if storagePercent <= 0.05 then return 0 end   -- Overdrive
    if storagePercent <= 0.20 then return 10 end
    
    -- Linear math: (x - in_min) * (out_max - out_min) / (in_max - in_min) + out_min
    local minS, maxS = 0.20, 0.80
    local minR, maxR = 10, 100
    return math.floor((storagePercent - minS) * (maxR - minR) / (maxS - minS) + minR)
end

local function getGridData()
    local data = {
        totalE = 0, totalM = 0,
        devices = {}, reactor = nil,
        rodLevel = 0, rActive = false
    }

    for _, name in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(name)
        local isPower = false
        local cur, max = 0, 0

        if name:find("BigReactors") then
            data.reactor = p
            local s, level = pcall(p.getControlRodLevel, 0)
            data.rodLevel = s and scrubToNum(level) or 0
            data.rActive = p.getActive()
        end

        local s1, v1 = pcall(p.getEnergyStored)
        local s2, v2 = pcall(p.getEnergyCapacity)
        local s3, v3 = pcall(p.getRFStored)
        local s4, v4 = pcall(p.getRFCapacity)

        if s1 and s2 then cur, max, isPower = scrubToNum(v1), scrubToNum(v2), true
        elseif s3 and s4 then cur, max, isPower = scrubToNum(v3), scrubToNum(v4), true end

        if isPower and max > 0 then
            data.totalE = data.totalE + cur
            data.totalM = data.totalM + max
            table.insert(data.devices, name)
        end
    end

    data.percent = (data.totalM > 0) and (data.totalE / data.totalM) or 0
    
    -- Flow & Overdrive logic
    if data.percent <= 0.05 and autoMode then
        energyFlow = "OVERDRIVE"
    else
        local diff = data.totalE - lastTotalEnergy
        if diff > 10 then energyFlow = "Charging"
        elseif diff < -10 then energyFlow = "Discharging"
        else energyFlow = "Stable" end
    end
    
    if data.totalE <= 0 and energyFlow ~= "OVERDRIVE" then energyFlow = "Empty" end
    lastTotalEnergy = data.totalE

    return data
end

-- =================================================================
-- UI Rendering
-- =================================================================
local function drawUI(mon, data)
    local w, h = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()

    mon.setTextScale(w < 40 and 0.5 or 1)
    mon.setCursorPos(2, 1)
    mon.setTextColor(colors.yellow)
    mon.write("Energy Maintenance System")

    -- Left Info Panel
    mon.setCursorPos(2, 3)
    mon.setTextColor(colors.white)
    mon.write("Energy: ")
    local col = colors.orange
    if energyFlow == "Charging" then col = colors.green
    elseif energyFlow == "OVERDRIVE" or energyFlow == "Empty" then col = colors.red end
    mon.setTextColor(col)
    mon.write(energyFlow)

    mon.setCursorPos(2, 5)
    mon.setTextColor(colors.white)
    mon.write("Automanage CTRL Rods: ")
    mon.setBackgroundColor(autoMode and colors.green or colors.red)
    mon.write(autoMode and " [ ON ] " or " [ OFF ] ")
    mon.setBackgroundColor(colors.black)

    if data.reactor then
        mon.setCursorPos(2, 7)
        mon.setTextColor(colors.white)
        mon.write("Rod Insertion: " .. data.rodLevel .. "%")
        
        mon.setCursorPos(2, 8)
        mon.write("Reactor Status: ")
        mon.setTextColor(data.rActive and colors.green or colors.red)
        mon.write(data.rActive and "active" or "inactive")

        -- Enable/Disable Buttons
        mon.setCursorPos(2, 10)
        mon.setBackgroundColor(colors.green)
        mon.setTextColor(colors.black)
        mon.write(" [ ENABLE ] ")
        
        mon.setCursorPos(15, 10)
        mon.setBackgroundColor(colors.red)
        mon.setTextColor(colors.white)
        mon.write(" [ DISABLE ] ")
        mon.setBackgroundColor(colors.black)
    end

    -- Battery Side (Right)
    local bX, bW = w - 4, 3
    mon.setCursorPos(bX - 4, 2) -- Moved 2 chars right as requested
    mon.setTextColor(colors.lightGray)
    mon.write("Storage %")

    local bH = h - 3
    local fill = math.floor(data.percent * (bH - 2))
    mon.setBackgroundColor(colors.gray)
    for y = 3, h-1 do
        mon.setCursorPos(bX, y) mon.write(" ")
        mon.setCursorPos(bX+bW, y) mon.write(" ")
    end
    for x = bX, bX+bW do
        mon.setCursorPos(x, 3) mon.write(" ")
        mon.setCursorPos(x, h-1) mon.write(" ")
    end

    mon.setBackgroundColor(colors.green)
    for i = 0, fill - 1 do
        mon.setCursorPos(bX+1, (h-2)-i)
        mon.write(string.rep(" ", bW-1))
    end

    -- Rod Graphic
    if data.reactor then
        local rX, rY = bX - 7, h - 2
        mon.setBackgroundColor(colors.black)
        mon.setTextColor(colors.gray)
        mon.setCursorPos(rX-1, rY-6) mon.write("RODS")
        for i = 0, 4 do
            local rc = colors.green
            if data.rodLevel == 100 then rc = colors.yellow
            elseif data.rodLevel >= 90 then
                rc = (i == 0) and colors.red or colors.yellow
            elseif data.rodLevel == 0 then rc = colors.red -- Solid red in Overdrive
            end
            mon.setBackgroundColor(rc)
            mon.setCursorPos(rX+1, rY-i) mon.write(" ")
        end
    end
end

-- =================================================================
-- Execution Loop
-- =================================================================
parallel.waitForAny(
    function() -- Monitor Touch
        while true do
            local _, _, x, y = os.pullEvent("monitor_touch")
            -- Toggle Automanage
            if y == 5 then autoMode = not autoMode end
            
            -- Enable Button
            if y == 10 and x < 14 then
                local names = peripheral.getNames()
                for _, n in ipairs(names) do
                    if n:find("BigReactors") then peripheral.call(n, "setActive", true) end
                end
            end
            
            -- Disable Button
            if y == 10 and x >= 14 then
                autoMode = false
                local names = peripheral.getNames()
                for _, n in ipairs(names) do
                    if n:find("BigReactors") then peripheral.call(n, "setActive", false) end
                end
            end
        end
    end,
    function() -- Main Logic
        while true do
            local data = getGridData()
            if data.reactor and autoMode then
                local target = calculateRodTarget(data.percent)
                data.reactor.setAllControlRodLevels(target)
            end
            for _, n in ipairs(peripheral.getNames()) do
                if peripheral.getType(n) == "monitor" then drawUI(peripheral.wrap(n), data) end
            end
            sleep(refreshRate)
        end
    end
)
