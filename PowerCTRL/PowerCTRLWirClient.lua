-- =================================================================
-- PowerCTRLWirClient.lua (Force-Sync Version)
-- =================================================================
term.clear()
term.setCursorPos(1,1)
print("--- EMS CLIENT SETUP ---")
write("Server Channel: ")
local input = read()
local channel = tonumber(input) or 55

local modem = peripheral.find("modem") or error("No wireless modem found!")
modem.open(channel)

local function drawUI(mon, data)
    if not data then return end
    
    -- 1. HARD RESET MONITOR STATE
    mon.setBackgroundColor(colors.black)
    mon.clear()
    mon.setCursorPos(1,1)
    
    local w, h = mon.getSize()
    local scale = (w < 30) and 0.5 or 1
    mon.setTextScale(scale)

    -- 2. DRAW HEADER
    mon.setCursorPos(2, 1)
    mon.setTextColor(colors.yellow)
    mon.write("EMS SYSTEM")

    -- 3. DRAW STORAGE BAR (Horizontal for better visibility)
    mon.setCursorPos(2, 3)
    mon.setTextColor(colors.white)
    local pCent = math.floor((data.percent or 0) * 100)
    mon.write("Storage: " .. pCent .. "%")
    
    mon.setCursorPos(2, 4)
    mon.setBackgroundColor(colors.gray)
    mon.write(string.rep(" ", w - 2)) -- Background of bar
    mon.setCursorPos(2, 4)
    mon.setBackgroundColor(colors.green)
    local barWidth = math.floor((data.percent or 0) * (w - 2))
    if barWidth > 0 then
        mon.write(string.rep(" ", barWidth))
    end
    mon.setBackgroundColor(colors.black)

    -- 4. REACTOR INFO
    mon.setCursorPos(2, 6)
    mon.setTextColor(colors.white)
    mon.write("Status: ")
    mon.setTextColor(data.active and colors.green or colors.red)
    mon.write(data.active and "ONLINE" or "OFFLINE")

    mon.setCursorPos(2, 7)
    mon.setTextColor(colors.lightBlue)
    mon.write(string.format("Gen: %.1f RF/t", data.prod or 0))

    -- 5. INTERACTIVE BUTTONS
    -- Positioning buttons at the very bottom
    mon.setCursorPos(2, h)
    mon.setBackgroundColor(colors.green)
    mon.setTextColor(colors.black)
    mon.write(" START ")
    
    mon.setCursorPos(w - 7, h)
    mon.setBackgroundColor(colors.red)
    mon.setTextColor(colors.white)
    mon.write(" STOP  ")
    mon.setBackgroundColor(colors.black)
end

print("\nWaiting for Server on channel " .. channel .. "...")

while true do
    local event, side, ch, reply, msg = os.pullEvent()
    
    if event == "modem_message" and type(msg) == "table" and msg.type == "DATA" then
        local found = false
        for _, n in ipairs(peripheral.getNames()) do
            if peripheral.getType(n) == "monitor" then
                found = true
                local m = peripheral.wrap(n)
                -- Force a redraw
                local ok, err = pcall(drawUI, m, msg.payload)
                if not ok then print("Render Error: " .. err) end
            end
        end
        
        if found then
            term.setCursorPos(1, 10)
            print("Successfully updated monitor at " .. textutils.formatTime(os.time(), true))
        end

    elseif event == "monitor_touch" then
        local _, mSide, x, y = event, side, ch, reply
        local m = peripheral.wrap(mSide)
        local mw, mh = m.getSize()
        
        -- Button logic mapped to the bottom row
        if y == mh then
            if x < 10 then 
                modem.transmit(channel, channel, {type="CMD", cmd="ON"})
            elseif x > mw - 10 then 
                modem.transmit(channel, channel, {type="CMD", cmd="OFF"})
            end
        end
    end
end
