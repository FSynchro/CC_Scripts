-- =================================================================
-- PowerCTRLWirRemote.lua (Optimized & Robust)
-- =================================================================
term.clear()
term.setCursorPos(1,1)
print("--- EMS REMOTE SETUP ---")
write("Target Channel: ")
local channel = tonumber(read()) or 48

local monitor = peripheral.find("monitor") or term
local modem = peripheral.find("modem", function(n, p) return p.isWireless() end)

if not modem then error("No Wireless Modem found!") end

-- Force close then open to ensure a clean connection
modem.close(channel)
modem.open(channel)

local lastData = nil
local serverTimeout = 12 
local timer = os.startTimer(serverTimeout)

local function drawUI(data)
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    
    if not data then
        monitor.setCursorPos(2, 2)
        monitor.setTextColor(colors.red)
        monitor.write("WAITING FOR SERVER (CH: "..channel..")...")
        return
    end

    -- Title
    monitor.setCursorPos(1, 1)
    monitor.setTextColor(colors.yellow)
    monitor.write(" REACTOR CONTROL SYSTEM ")
    
    -- Energy Bar
    local width, height = monitor.getSize()
    local barWidth = width - 4
    local filled = math.floor(barWidth * data.percent)
    
    monitor.setCursorPos(2, 3)
    monitor.setTextColor(colors.white)
    monitor.write("Storage: " .. math.floor(data.percent * 100) .. "%")
    
    monitor.setCursorPos(2, 4)
    monitor.setBackgroundColor(colors.gray)
    monitor.write(string.rep(" ", barWidth))
    monitor.setCursorPos(2, 4)
    monitor.setBackgroundColor(data.percent > 0.2 and colors.green or colors.red)
    monitor.write(string.rep(" ", filled))
    monitor.setBackgroundColor(colors.black)

    -- Stats
    monitor.setCursorPos(2, 6)
    monitor.setTextColor(colors.cyan)
    monitor.write("Flow:   " .. (data.flow or "N/A"))
    monitor.setCursorPos(2, 7)
    monitor.write("Output: " .. math.floor(data.prod or 0) .. " RF/t")
    monitor.setCursorPos(2, 8)
    monitor.write("Rods:   " .. (data.rods or 0) .. "%")

    -- Buttons
    monitor.setCursorPos(2, 10)
    monitor.setBackgroundColor(data.auto and colors.blue or colors.lightGray)
    monitor.write(" [AUTO] ")
    
    monitor.setCursorPos(12, 10)
    monitor.setBackgroundColor(data.active and colors.green or colors.red)
    monitor.write(data.active and " [ON] " or " [OFF] ")
    monitor.setBackgroundColor(colors.black)
end

drawUI(nil) -- Show initial waiting screen

while true do
    local ev, side, ch, rep, msg = os.pullEvent()

    if ev == "modem_message" and ch == channel then
        if msg and msg.type == "DATA" then
            lastData = msg
            drawUI(msg)
            -- Reset the watchdog timer
            os.cancelTimer(timer)
            timer = os.startTimer(serverTimeout)
        end
    elseif ev == "timer" and side == timer then
        -- Server heartbeat lost
        lastData = nil
        drawUI(nil)
        timer = os.startTimer(serverTimeout)
    elseif ev == "monitor_touch" or ev == "mouse_click" then
        local x, y = side, ch 
        if y == 10 then
            if x >= 2 and x <= 9 then
                modem.transmit(channel, channel, {type = "CMD", cmd = "TOGGLE_AUTO"})
            elseif x >= 12 and x <= 18 then
                local cmd = (lastData and lastData.active) and "OFF" or "ON"
                modem.transmit(channel, channel, {type = "CMD", cmd = cmd})
            end
        end
    end
end
