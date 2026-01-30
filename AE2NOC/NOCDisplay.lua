-- =================================================================
-- NOCDisplay.lua - Central Processing & UI
-- =================================================================
local mon = peripheral.find("monitor") or term
local modem = peripheral.find("modem", function(_, p) return p.isWireless() end) 
    or error("No Modem")

modem.open(1422) -- Cell Data
modem.open(1428) -- Main/CPU Data

-- Data Globals
local storageData = { maxBytes = 0, maxTypes = 0, counts = {} }
local mainData = { totalItems = 0, usedTypes = 0, yellorium = 0 }
local cpuData = { count = 0, busy = 0, avgCoPro = 0, avgStore = 0 }

-- Drive Specs for Calculation
local driveSpecs = {
    ["appliedenergistics2:storage_cell_1k"] = 1024,
    ["appliedenergistics2:storage_cell_4k"] = 4096,
    ["appliedenergistics2:storage_cell_16k"] = 16384,
    ["appliedenergistics2:storage_cell_64k"] = 65536,
    ["extracells:storage.physical"] = { [0] = 256000, [1] = 1024000, [2] = 4096000, [3] = 16384000 }
}

local function formatValue(val)
    if val >= 10^6 then return string.format("%.1fMB", val / 1048576)
    elseif val >= 10^3 then return string.format("%.1fKB", val / 1024)
    end
    return val .. "B"
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
    local fillWidth = math.floor(progress * width)
    mon.setCursorPos(x, y); mon.setBackgroundColor(colors.lightGray); mon.write(string.rep(" ", width))
    mon.setCursorPos(x, y); mon.setBackgroundColor(progress < 0.8 and colors.lime or colors.red); mon.write(string.rep(" ", fillWidth))
    mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white); mon.setCursorPos(x + width + 1, y); mon.write(math.floor(progress * 100) .. "%")
end

local function drawCPUGrid(x, y)
    local totalPixels = 64
    local busyPixels = cpuData.count > 0 and math.floor((cpuData.busy / cpuData.count) * totalPixels) or 0
    for i = 0, totalPixels - 1 do
        mon.setCursorPos(x + (i % 8), y + math.floor(i / 8))
        mon.setBackgroundColor(i < busyPixels and colors.red or colors.lime)
        mon.write(" ")
    end
    mon.setBackgroundColor(colors.black)
end

local function refreshUI()
    mon.clear()
    drawBox(2, 28, 2, 12, "STORAGE STATISTICS", colors.yellow)
    drawBox(30, 52, 2, 12, "SYSTEM STATUS", colors.orange)
    drawBox(2, 52, 14, 24, "CELL INVENTORY", colors.lightBlue)

    -- Bars
    local usedBytes = math.floor(mainData.totalItems / 8)
    drawBar(4, 5, 16, usedBytes, storageData.maxBytes)
    drawBar(4, 9, 16, mainData.usedTypes, storageData.maxTypes)
    
    -- System Text
    mon.setTextColor(colors.green); mon.setCursorPos(32, 4); mon.write("T-B: " .. formatValue(storageData.maxBytes))
    mon.setTextColor(colors.red);   mon.setCursorPos(32, 5); mon.write("U-B: " .. formatValue(usedBytes))
    mon.setTextColor(colors.yellow);mon.setCursorPos(32, 6); mon.write("A-B: " .. formatValue(storageData.maxBytes - usedBytes))
    
    mon.setTextColor(colors.green); mon.setCursorPos(32, 8); mon.write("T-T: " .. storageData.maxTypes)
    mon.setTextColor(colors.red);   mon.setCursorPos(32, 9); mon.write("U-T: " .. mainData.usedTypes)
    mon.setTextColor(colors.yellow);mon.setCursorPos(32, 10);mon.write("A-T: " .. (storageData.maxTypes - mainData.usedTypes))

    -- CPU Grid Section
    mon.setTextColor(colors.white); mon.setCursorPos(32, 14); mon.write("CRAFTING GRID")
    drawCPUGrid(43, 15)
    mon.setCursorPos(32, 16); mon.write("CPUs: " .. cpuData.count)
    mon.setCursorPos(32, 17); mon.write("Busy: " .. cpuData.busy)
    mon.setCursorPos(32, 18); mon.write("CoP: " .. string.format("%.1f", cpuData.avgCoPro))

    -- Cell List
    local line = 16
    for label, count in pairs(storageData.counts) do
        if line < 23 then
            mon.setCursorPos(4, line); mon.setTextColor(colors.white); mon.write("- " .. label .. " Cell: "); mon.setTextColor(colors.lime); mon.write("["..count.."]")
            line = line + 1
        end
    end
end

-- MAIN LOOP
while true do
    local _, _, chan, _, msg = os.pullEvent("modem_message")
    
    if chan == 1422 then -- Process Cell Data
        storageData = { maxBytes = 0, maxTypes = 0, counts = {} }
        for _, it in ipairs(msg.items) do
            local cap = 0
            local label = ""
            if driveSpecs[it.name] then
                if type(driveSpecs[it.name]) == "table" then
                    cap = driveSpecs[it.name][it.damage] or 0
                    label = math.floor(cap/1024).."k"
                else
                    cap = driveSpecs[it.name]
                    label = it.name:match("storage_cell_(%d+k)") or "1k"
                end
                storageData.maxBytes = storageData.maxBytes + (cap * it.count)
                storageData.maxTypes = storageData.maxTypes + (63 * it.count)
                storageData.counts[label] = (storageData.counts[label] or 0) + it.count
            end
        end
    elseif chan == 1428 then -- Process Main/CPU Data
        mainData.totalItems = 0
        mainData.usedTypes = #msg.items
        for _, it in ipairs(msg.items) do
            mainData.totalItems = mainData.totalItems + it.count
        end
        
        local totalCo, totalSt, busy = 0, 0, 0
        for _, c in ipairs(msg.cpus) do
            totalCo = totalCo + (c.coprocessors or 0)
            if c.busy then busy = busy + 1 end
        end
        cpuData = { 
            count = #msg.cpus, 
            busy = busy, 
            avgCoPro = #msg.cpus > 0 and totalCo/#msg.cpus or 0 
        }
        refreshUI() -- Refresh screen after the main 2-second update
    end
end
