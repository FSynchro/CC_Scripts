-- =================================================================
-- PowerCTRLWirRemote.lua (Optimized Edition)
-- =================================================================
local monitor = peripheral.find("monitor") or term
local channel = 48 -- Set this to match your Server channel

local modem = peripheral.find("modem", function(n, p) return p.isWireless() end)
if not modem then error("No Wireless Modem found!") end
modem.open(channel)

local lastData = nil
local serverTimeout = 12 -- Wait up to 12s since server updates every 5s

local function drawUI(data)
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    monitor.setTextScale(1)
    
    if not data then
        monitor.setCursorPos(2, 2)
        monitor.setTextColor(colors.red)
        monitor.write("WAITING FOR SERVER...")
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
    monitor.write("Flow:   " .. data.flow)
    
    monitor.setCursorPos(2, 7)
    monitor.write("Output: " .. math.floor(data.prod) .. " RF/t")
    
    monitor.setCursorPos(2, 8)
    monitor.write("Rods:   " .. data.rods .. "%")

    -- Buttons (Visual Only)
    monitor.setCursorPos(2, 10)
    monitor.setBackgroundColor(data.auto and colors.blue or colors.lightGray)
    monitor.write(" [AUTO] ")
    
    monitor.setCursorPos(12, 10)
    monitor.setBackgroundColor(data.active and colors.green or colors.red)
    monitor.write(data.active and " [ON] " or " [OFF] ")
    monitor.setBackgroundColor(colors.black)
end

local function sendCmd(command)
    modem.transmit(channel, channel, {type = "CMD", cmd = command})
end

-- Main Loop
drawUI(nil)

while true do
    local timer = os.startTimer(serverTimeout)
    local ev, side, ch, rep, msg, dist = os.pullEvent()

    if ev == "modem_message" and msg and msg.type == "DATA" then
        lastData = msg
        drawUI(msg)
    elseif ev == "timer" and side == timer then
        -- Server hasn't checked in for 12 seconds
        lastData = nil
        drawUI(nil)
    elseif ev == "monitor_touch" or ev == "mouse_click" then
        local x, y = side, ch -- Re-mapping vars based on event
        -- Simple Button Logic (Approximate positions)
        if y == 10 then
            if x >= 2 and x <= 9 then
                sendCmd("TOGGLE_AUTO")
            elseif x >= 12 and x <= 18 then
                if lastData and lastData.active then sendCmd("OFF") else sendCmd("ON") end
            end
        end
    end
end
