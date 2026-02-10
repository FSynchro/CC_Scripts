local rootDir = "/CC_Scripts"

-- Helper to center text on screen
local function center(text)
    local w, _ = term.getSize()
    local x = math.floor((w - #text) / 2) + 1
    term.setCursorPos(x, select(2, term.getCursorPos()))
    print(text)
end

local function drawHeader()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1,1)
    
    term.setTextColor(colors.gray)
    print("---------------------------------------------------")
    term.setTextColor(colors.cyan)
    center("  _____  ______     ___   _  ____")
    center(" |  ___|/ ___\\ \\   / / \\ | |/ ___|")
    center(" | |_   \\___ \\\\ \\ / /|  \\| | |    ")
    center(" |  _|   ___) |\\ V / | |\\  | |___ ")
    center(" |_|    |____/  |_|  |_| \\_|\\____|")
    
    print("")
    term.setTextColor(colors.yellow)
    center("[ Computer startup configuration utility ]")
    term.setTextColor(colors.gray)
    print("---------------------------------------------------")
    term.setTextColor(colors.white)
    center("Select a program to auto-start")
    center("on system reboot.")
    print("---------------------------------------------------")
end

local function getScripts(dir, fileList)
    fileList = fileList or {}
    if not fs.exists(dir) or not fs.isDir(dir) then return fileList end
    
    local list = fs.list(dir)
    for _, file in ipairs(list) do
        local path = fs.combine(dir, file)
        if fs.isDir(path) then
            getScripts(path, fileList) -- Recurse without adding GPS again
        elseif file:sub(-4) == ".lua" and file ~= "startupmaker.lua" and file ~= "startup.lua" then
            table.insert(fileList, path)
        end
    end
    return fileList
end

local function drawMenu(scripts, selected)
    drawHeader()
    local w, h = term.getSize()
    
    for i, path in ipairs(scripts) do
        if i >= selected - 3 and i <= selected + 3 then
            if i == selected then
                term.setBackgroundColor(colors.lightGray)
                term.setTextColor(colors.black)
                term.clearLine()
                term.write("> " .. path)
                print("")
                term.setBackgroundColor(colors.black)
            else
                term.setTextColor(colors.white)
                print("  " .. path)
            end
        end
    end
    
    term.setCursorPos(1, h)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.clearLine()
    term.write(" [UP/DOWN] Move | [ENTER] Save | [Q] Quit")
    term.setBackgroundColor(colors.black)
end

-- MAIN LOGIC
local scripts = getScripts(rootDir)
table.sort(scripts)
table.insert(scripts, 1, "GPS Automanage")

local selected = 1

while true do
    drawMenu(scripts, selected)
    local event, key = os.pullEvent("key")
    
    if key == keys.up then
        selected = selected > 1 and selected - 1 or #scripts
    elseif key == keys.down then
        selected = selected < #scripts and selected + 1 or 1
    elseif key == keys.q then
        term.clear()
        term.setCursorPos(1,1)
        break
    elseif key == keys.enter then
        local target = scripts[selected]
        local f = fs.open("startup.lua", "w")
        
        if target == "GPS Automanage" then
            -- GPS LOGIC
            term.clear()
            term.setCursorPos(1,1)
            print("Locating GPS satellites...")
            
            -- Try to find position
            local x, y, z = gps.locate(2)
            x = x or "x"
            y = y or "y"
            z = z or "z"
            
            f.writeLine("-- GPS AUTOMANAGE STARTUP")
            f.writeLine(string.format("shell.run('gps', 'host', '%s', '%s', '%s')", tostring(x), tostring(y), tostring(z)))
            f.close()
        else
            -- ORIGINAL FSYNC LOGIC
            f.writeLine("-- FSYNC AUTO-UPDATING BOOT")
            f.writeLine("print('Checking for updates...')")
            f.writeLine("if fs.exists('" .. rootDir .. "') then fs.delete('" .. rootDir .. "') end")
            f.writeLine("shell.run('clone.min https://github.com/FSynchro/CC_Scripts')")
            f.writeLine("if fs.exists('" .. target .. "') then")
            f.writeLine("  shell.run('" .. target .. "')")
            f.writeLine("else")
            f.writeLine("  print('Error: Target script not found after update.')")
            f.writeLine("  print('Path: " .. target .. "')")
            f.writeLine("end")
            f.close()
        end
        
        -- UI Confirmation
        local w, h = term.getSize()
        term.setBackgroundColor(colors.blue)
        term.clear()
        term.setCursorPos(1, math.floor(h/2))
        term.setTextColor(colors.white)
        center("BOOT CONFIGURATION SAVED")
        center("Target: " .. target)
        center("Rebooting computer...")
        sleep(1.5)
        os.reboot()
    end
end
