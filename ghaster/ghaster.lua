local modules = peripheral.wrap("back")

local targetName = "F_Synchro" 
local idealDist = 8    -- Increased to give you more room
local hoverHeight = 4  -- How many blocks above your head it wants to be
local floatTick = 0    -- Used for the bobbing effect

print("Majestic Hover Initialized...")

while true do
    local entities = modules.sense()
    local me = nil

    for i = 1, #entities do
        if entities[i].name == targetName or entities[i].displayName == targetName then
            me = entities[i]
            break
        end
    end

    if me then
        -- 1. Horizontal distance and angles
        local dist = math.sqrt(me.x^2 + me.z^2)
        local yaw = math.atan2(me.z, me.x)
        
        -- 2. Vertical Logic (Aiming for the head + hoverHeight)
        -- We calculate the 'error' in height
        local heightError = me.y + hoverHeight
        
        -- 3. The "Floaty" Effect
        -- We add a sine wave nudge to the height target
        floatTick = floatTick + 0.2
        local bobbing = math.sin(floatTick) * 0.5
        local finalHeightTarget = heightError + bobbing

        -- 4. Look at the Player
        -- We keep the look pitch pointing slightly down so it 'stares' at you
        local lookPitch = math.atan2(me.y, dist)
        modules.look(math.deg(yaw) - 90, math.deg(-lookPitch))

        -- 5. Movement (The Tether)
        local xPower, yPower, zPower = 0, 0, 0
        
        -- Horizontal Nudge
        if dist > idealDist then
            local p = math.min((dist - idealDist) * 0.1, 0.4)
            xPower = math.cos(yaw) * p
            zPower = math.sin(yaw) * p
        end
        
        -- Vertical Nudge (The Height Follower)
        if math.abs(finalHeightTarget) > 0.5 then
            yPower = math.min(finalHeightTarget * 0.2, 0.4)
        end

        -- 6. Launch with 3D Vectors
        -- Note: We use the direct x,y,z launch if your version supports it, 
        -- otherwise we use the (yaw, pitch, power) method.
        if modules.launch then
            -- Re-calculating vector to (yaw, pitch, power) for standard Plethora
            local vectorYaw = math.deg(math.atan2(zPower, xPower)) - 90
            local totalPower = math.sqrt(xPower^2 + yPower^2 + zPower^2)
            local vectorPitch = math.deg(math.asin(yPower / (totalPower + 0.001)))
            
            if totalPower > 0.01 then
                modules.launch(vectorYaw, -vectorPitch, totalPower)
            end
        end
    else
        print("Searching for Master...")
    end

    sleep(0.1)
end
