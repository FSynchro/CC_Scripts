-- =================================================================
-- PowerCTRLWirServer.lua (Dual Modem Edition)
-- =================================================================
term.clear()
term.setCursorPos(1,1)
print("--- EMS SERVER SETUP ---")
write("Wireless Channel: ")
local channel = tonumber(read()) or 48

-- 1. Identify Modems by Type
local wirelessModem, wiredModem
for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if peripheral.getType(name) == "modem" then
        if p.isWireless() then
            wirelessModem = p
        else
            wiredModem = p
        end
    end
end

if not wirelessModem then error("Wireless Modem NOT found!") end
wirelessModem.open(channel)
print("Wireless Link: Online (Ch " .. channel .. ")")

local lastE = 0

while true do
    local totalE, totalM, rProd, rActive, rRods = 0, 0, 0, false, 0
    local reactor = nil

    -- 2. Scan for peripherals (Reactor/Energy)
    -- This works across the cables automatically
    for _, name in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(name)
        
        -- Check for Energy (Capacitors/Cells)
        local s1, v1 = pcall(p.getEnergyStored)
        local s2, v2 = pcall(p.getEnergyCapacity)
        if s1 and s2 then
            totalE = totalE + v1
            totalM = totalM + v2
        end
        
        -- Check for Big Reactor
        if name:find("BigReactors") then
            reactor = p
            rActive = p.getActive()
            rRods = p.getControlRodLevel(0)
            local s3, v3 = pcall(p.getEnergyStats)
            rProd = s3 and v3.energyProducedLastTick or 0
        end
    end

    local pct = (totalM > 0) and (totalE / totalM) or 0
    local flow = (totalE > lastE) and "Charging" or (totalE < lastE and "Discharging" or "Stable")
    lastE = totalE

    -- 3. Transmit ONLY over the Wireless Modem
    wirelessModem.transmit(channel, channel, {
        type = "DATA",
        percent = pct,
        active = rActive,
        rods = rRods,
        prod = rProd,
        flow = flow
    })

    -- 4. Command Listener (Fixed Timeout)
    local timer = os.startTimer(0.5)
    while true do
        local event, side, ch, rep, msg = os.pullEvent()
        if event == "modem_message" and ch == channel then
            if msg and msg.type == "CMD" and reactor then
                if msg.cmd == "ON" then reactor.setActive(true)
                elseif msg.cmd == "OFF" then reactor.setActive(false) end
            end
            break
        elseif event == "timer" and side == timer then
            break
        end
    end
end
