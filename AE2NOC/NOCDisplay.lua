-- =================================================================
-- NOCDisplay.lua - Final v11 (Precision Right-Side Alignment)
-- =================================================================
local mon = peripheral.find("monitor") or term
local modem = peripheral.find("modem", function(_, p) return p.isWireless() end) 
    or error("No Modem")

mon.setTextScale(0.5)

modem.open(1422) 
modem.open(1428)

local currentTab = 1
local debugLog = {
    [1422] = { lastSeen = "Never", status = "Waiting..." },
    [1428] = { lastSeen = "Never", status = "Waiting..." }
}

local storageData = { maxBytes = 0, maxTypes = 0, counts = {} }
local mainData = { totalItems = 0, usedTypes = 0 }
local cpuData = { count = 0, busy = 0 }

local driveSpecs = {
    ["appliedenergistics2:storage_cell_1k"] = 1024,
    ["appliedenergistics2:storage_cell_4k"] = 4096,
    ["appliedenergistics2:storage_cell_16k"] = 16384,
    ["appliedenergistics2:storage_cell_64k"] = 65536,
    ["extracells:storage.physical"] = { [0] = 256000, [1] = 1024000, [2] = 4096000, [3] = 16384000 }
}

local function formatValue(val)
    if val >= 1048576 then return string.format("%.1fMB", val / 1048576)
    elseif val >= 1024 then return string.format("%.1fKB", val / 1024)
    end
    return val .. "B"
end

local function drawTabs()
    mon.setCursorPos(2, 1)
    mon.setBackgroundColor(currentTab == 1 and colors.lime or colors.gray)
    mon.setTextColor(colors.black)
    mon.write(" [ 1: DASH ] ")

    mon.setCursorPos(15, 1)
    mon.setBackgroundColor(currentTab == 2 and colors.yellow or colors.gray)
    mon.setTextColor(colors.black)
    mon.write(" [ 2: DEBUG ] ")
    
    mon.setBackgroundColor(colors.black)
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
    mon.setCursorPos(xMin + 2, yMin); mon.setBackgroundColor(colors.black)
    mon.setTextColor(titleColor); mon.write(" " .. title .. " ")
end

local function drawBar(x, y, width, current, max)
    local progress = math.min(math.max(current / (max > 0 and max or 1), 0), 1)
    mon.setCursorPos(x, y); mon.setBackgroundColor(colors.lightGray); mon.write(string.rep(" ", width))
    mon.setCursorPos(x, y); mon.setBackgroundColor(progress < 0.8 and colors.lime or colors.red)
    mon.write(string.rep(" ", math.floor(progress * width)))
    mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white); mon.setCursorPos(x+width+1, y); mon.write(math.floor(progress*100).."%")
end

local function drawCPUGrid(x, y)
    local totalPixels = 64
    local busyPixels = cpuData.count > 0 and math.floor((cpuData.busy / cpuData.count) * totalPixels) or 0
    for i = 0, 31 do 
        local col = i % 8
        local row = math.floor(i / 8)
        local topPixelIdx = (row * 16) + col
        local botPixelIdx = (row * 16) + col + 8
        local topColor = (topPixelIdx < busyPixels) and colors.red or colors.lime
        local botColor = (botPixelIdx < busyPixels) and colors.red or colors.lime
        if cpuData.count == 0 then topColor, botColor = colors.gray, colors.gray end
        mon.setCursorPos(x + col, y + row)
        mon.setBackgroundColor(botColor); mon.setTextColor(topColor); mon.write("\143") 
    end
    mon.setBackgroundColor(colors.black)
end

local function refreshUI()
    if currentTab == 2 then 
        mon.clear(); drawTabs()
        mon.setTextColor(colors.white); mon.setCursorPos(2, 4); mon.write("MODEM DIAGNOSTICS")
        local row = 7
        for chan, data in pairs(debugLog) do
            mon.setCursorPos(2, row); mon.setTextColor(colors.cyan); mon.write("Channel " .. chan .. ": ")
            mon.setTextColor(colors.white); mon.write(data.status)
            mon.setCursorPos(2, row + 1); mon.setTextColor(colors.gray); mon.write(" Last RX: " .. data.lastSeen)
            row = row + 3
        end
        return 
    end
    
    mon.clear(); drawTabs()
    
    -- BOX 1: Left Top (NETWORK STATISTICS)
    drawBox(2, 29, 3, 12, "NETWORK STATISTICS", colors.yellow)
    mon.setTextColor(colors.white)
    mon.setCursorPos(4, 5); mon.write("Storage (Bytes)")
    drawBar(4, 6, 17, math.floor(mainData.totalItems / 8), storageData.maxBytes)
    mon.setCursorPos(4, 9); mon.write("Types (Unique)")
    drawBar(4, 10, 17, mainData.usedTypes, storageData.maxTypes)
    
    -- BOX 2: Right Top (SYSTEM) - Extended 4 right
    drawBox(31, 56, 3, 12, "SYSTEM", colors.orange)
    local usedBytes = math.floor(mainData.totalItems / 8)
    mon.setCursorPos(33, 5); mon.setTextColor(colors.green);  mon.write("TOT: "..formatValue(storageData.maxBytes))
    mon.setCursorPos(33, 6); mon.setTextColor(colors.red);    mon.write("USD: "..formatValue(usedBytes))
    mon.setCursorPos(33, 7); mon.setTextColor(colors.yellow); mon.write("AVL: "..formatValue(math.max(0, storageData.maxBytes - usedBytes)))
    mon.setCursorPos(33, 9); mon.setTextColor(colors.green);  mon.write("T-TYP: "..storageData.maxTypes)
    mon.setCursorPos(33, 10); mon.setTextColor(colors.red);    mon.write("U-TYP: "..mainData.usedTypes)
    mon.setCursorPos(33, 11); mon.setTextColor(colors.yellow); mon.write("A-TYP: "..math.max(0, storageData.maxTypes - mainData.usedTypes))

    -- BOX 3: Left Bottom (CELLS)
    drawBox(2, 29, 14, 28, "DETECTED STORAGE CELLS", colors.lightBlue)
    local line = 16
    local sorted = {}
    for k in pairs(storageData.counts) do table.insert(sorted, k) end
    table.sort(sorted)
    for _, label in ipairs(sorted) do
        if line < 27 then
            mon.setCursorPos(4, line); mon.setTextColor(colors.white); mon.write("- "..label.." Cell: ")
            mon.setTextColor(colors.lime); mon.write("["..storageData.counts[label].."]"); line = line + 1
        end
    end

    -- BOX 4: Right Bottom (CRAFTING) - Extended 4 right
    drawBox(31, 56, 14, 28, "CRAFTING STATUS", colors.magenta)
    drawCPUGrid(44, 16) 
    mon.setTextColor(colors.white)
    mon.setCursorPos(33, 21); mon.write("CPUs:  ")
    mon.setTextColor(cpuData.count == 0 and colors.red or colors.lime); mon.write(cpuData.count)
    mon.setTextColor(colors.white)
    mon.setCursorPos(33, 22); mon.write("Busy:  " .. cpuData.busy)
    local cpuLoad = cpuData.count > 0 and math.floor((cpuData.busy/cpuData.count)*100) or 0
    mon.setCursorPos(33, 23); mon.write("Load:  " .. cpuLoad .. "%")
end

-- Logic Loop (Unchanged)
while true do
    local event, side, x, y, msg = os.pullEvent()
    if event == "monitor_touch" then
        if y == 1 then
            if x >= 2 and x <= 13 then currentTab = 1; refreshUI() end
            if x >= 15 and x <= 26 then currentTab = 2; refreshUI() end
        end
    elseif event == "modem_message" then
        local chan, data = x, msg
        if type(data) == "table" then
            if debugLog[chan] then debugLog[chan].lastSeen = os.date("%H:%M:%S"); debugLog[chan].status = "ONLINE" end
            if chan == 1422 and data.items then
                storageData = { maxBytes = 0, maxTypes = 0, counts = {} }
                for _, it in ipairs(data.items) do
                    if driveSpecs[it.name] then
                        local cap = (type(driveSpecs[it.name]) == "table") and (driveSpecs[it.name][it.damage] or 0) or driveSpecs[it.name]
                        local label = (type(driveSpecs[it.name]) == "table") and (math.floor(cap/1024).."k") or (it.name:match("storage_cell_(%d+k)") or "1k")
                        storageData.maxBytes = storageData.maxBytes + (cap * it.count)
                        storageData.maxTypes = storageData.maxTypes + (63 * it.count)
                        storageData.counts[label] = (storageData.counts[label] or 0) + it.count
                    end
                end
            elseif chan == 1428 and data.items and data.cpus then
                mainData.totalItems, mainData.usedTypes = 0, 0
                for _, it in ipairs(data.items) do 
                    mainData.totalItems = mainData.totalItems + it.count 
                    if it.count > 0 then mainData.usedTypes = mainData.usedTypes + 1 end
                end
                local busy = 0
                for _, c in ipairs(data.cpus) do if c.busy then busy = busy + 1 end end
                cpuData = { count = #data.cpus, busy = busy }
            end
            refreshUI()
        end
    end
end
