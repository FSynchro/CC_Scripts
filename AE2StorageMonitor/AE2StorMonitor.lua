-- =================================================================
-- AE2StorMonitor.lua - FULL RESTORED VERSION
-- =================================================================
local wirelessModem
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then
        wirelessModem = name
        break
    end
end

if not wirelessModem then error("No Wireless Modem found!") end
local me = peripheral.find("appliedenergistics2:interface") or error("No ME Interface found")
local mon = peripheral.find("monitor") or term
local CHANNEL = 1422
local BROADCAST_CHANNEL = 1425 

peripheral.call(wirelessModem, "open", CHANNEL)

local function getStatusColor(percent)
    if percent < 0.60 then return colors.lime end
    if percent < 0.85 then return colors.yellow end
    return colors.red
end

local function drawBox(xMin, xMax, yMin, yMax, title, titleColor)
    mon.setBackgroundColor(colors.gray)
    for x = xMin, xMax do
        mon.setCursorPos(x, yMin); mon.write(" ")
        mon.setCursorPos(x, yMax); mon.write(" ")
    end
    for y = yMin, yMax do
        mon.setCursorPos(xMin, y); mon.write(" ")
        mon.setCursorPos(xMax, y); mon.write(" ")
    end
    mon.setCursorPos(xMin + 2, yMin)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(titleColor or colors.white)
    mon.write(" " .. title .. " ")
end

local function drawBar(x, y, width, current, max)
    local progress = math.min(math.max(current / (max > 0 and max or 1), 0), 1)
    local fillWidth = math.floor(progress * width)
    local barColor = getStatusColor(progress)
    
    mon.setCursorPos(x, y)
    mon.setBackgroundColor(colors.lightGray)
    mon.write(string.rep(" ", width))
    
    mon.setCursorPos(x, y)
    mon.setBackgroundColor(barColor)
    mon.write(string.rep(" ", fillWidth))
    
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(barColor)
    mon.setCursorPos(x + width + 1, y)
    mon.write(math.floor(progress * 100) .. "% ")
end

local function drawDriveArt(x, y)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.gray)
    mon.setCursorPos(x, y);   mon.write("  ______  ")
    mon.setCursorPos(x, y+1); mon.write(" |      | ")
    mon.setCursorPos(x, y+2); mon.write(" | [@@] | ")
    mon.setTextColor(colors.lime)
    mon.setCursorPos(x, y+3); mon.write(" | [@@] | ")
    mon.setTextColor(colors.gray)
    mon.setCursorPos(x, y+4); mon.write(" |______| ")
end

local subnetData = nil
local isOnline = false

mon.setBackgroundColor(colors.black)
mon.clear()

while true do
    if subnetData and not isOnline then
        mon.clear()
        drawBox(2, 28, 2, 12, "NETWORK STATISTICS", colors.yellow)
        drawBox(30, 52, 2, 8, "SYSTEM", colors.orange)
        drawBox(2, 52, 14, 24, "DETECTED STORAGE CELLS", colors.lightBlue)
        drawDriveArt(36, 9)
        isOnline = true
    end

    if not subnetData then
        mon.setTextColor(colors.red)
        mon.setBackgroundColor(colors.black)
        mon.setCursorPos(5, 7)
        mon.write("OFFLINE: WAITING FOR DATA...")
    else
        local mainItems = me.listAvailableItems()
        local usedTypes = #mainItems
        local totalItems = 0
        local yelloriumCount = 0

-- SCANNING FOR YELLORIUM (Fixed with exact ID)
        for _, it in ipairs(mainItems) do 
            totalItems = totalItems + it.count 
            
            -- Exact ID check + Display Name fallback
            if it.name == "bigreactors:ingotyellorium" or (it.displayName and it.displayName:find("Yellorium Ingot")) then
                yelloriumCount = it.count
            end
        end

        -- BROADCAST TO POWER MONITOR
        peripheral.call(wirelessModem, "transmit", BROADCAST_CHANNEL, CHANNEL, {
            type = "AE2_DATA",
            count = yelloriumCount
        })

        local usedBytes = math.floor(totalItems / 8)
        mon.setBackgroundColor(colors.black)
        mon.setTextColor(colors.white)
        mon.setCursorPos(4, 4); mon.write("Storage (Bytes)   ")
        drawBar(4, 5, 18, usedBytes, subnetData.maxBytes)
        
        mon.setTextColor(colors.white)
        mon.setCursorPos(4, 8); mon.write("Types (Unique)     ")
        drawBar(4, 9, 18, usedTypes, subnetData.maxTypes)

        mon.setCursorPos(32, 4); mon.setTextColor(colors.green);  mon.write("TOT: " .. subnetData.maxBytes .. "      ")
        mon.setCursorPos(32, 5); mon.setTextColor(colors.red);    mon.write("USD: " .. usedBytes .. "      ")
        mon.setCursorPos(32, 6); mon.setTextColor(colors.yellow); mon.write("AVL: " .. math.max(0, subnetData.maxBytes - usedBytes) .. "      ")

        for i = 16, 23 do
            mon.setCursorPos(3, i); mon.write(string.rep(" ", 48))
        end

        local line = 16
        local sortedLabels = {}
        for label in pairs(subnetData.counts) do table.insert(sortedLabels, label) end
        table.sort(sortedLabels)

        for _, label in ipairs(sortedLabels) do
            if line < 23 then
                mon.setCursorPos(5, line)
                mon.setTextColor(colors.white); mon.write("- " .. label .. " Cell: ")
                mon.setTextColor(colors.lime);  mon.write("[" .. subnetData.counts[label] .. "]")
                line = line + 1
            end
        end
    end

    local timer = os.startTimer(2)
    while true do
        local event, side, channel, _, msg = os.pullEvent()
        if event == "modem_message" and channel == 1422 then
            subnetData = msg
            break 
        elseif event == "timer" and side == timer then
            break 
        end
    end
end
