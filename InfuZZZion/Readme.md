# Thaumcraft Infusion Automation System v3.0

## Overview
This system automates Thaumcraft infusion crafting using ComputerCraft turtles and computers. Version 3.0 uses a new architecture based on **catalyst pedestal computers** instead of expensive block scanning.

## Major Changes from v2.0

### ✅ NEW: Catalyst Pedestal Computers
- Each infusion altar now requires a **computer placed directly below the catalyst pedestal**
- The computer monitors the pedestal using `peripheral.wrap("top")` to detect infusion completion
- No more expensive scanner energy costs!
- More reliable detection of infusion completion

### ✅ Removed: Block Scanner
- No longer uses Plethora block scanner
- No more scanner energy management
- No more scanning for mana infused steel blocks
- Setup is faster and simpler

### ✅ Improved: Turtle Behavior
- Turtles now scan pedestals around each altar during setup
- Better task assignment for clearing pedestals after infusion
- Fixed ID assignment issues

## System Components

### 1. Server Computer (server.lua)
**Location:** Central control computer with:
- **Right side:** Input chest (contains catalyst + ingredients)
- **Top:** Ender modem
- **GPS:** Required for coordinate tracking

**Functions:**
- Manages recipe database
- Coordinates turtle tasks
- Receives altar registrations from catalyst pedestal computers
- Monitors infusion progress
- Handles recipe matching

### 2. Catalyst Pedestal Computer (catalystpedestalcomputer.lua)
**Location:** Directly **below each catalyst pedestal**
- **Top:** Thaumcraft catalyst pedestal
- **Any side:** Ender modem
- **GPS:** Required (runs once at startup)

**Functions:**
- Registers altar location with server
- Monitors pedestal for item changes (detects infusion completion)
- Reports when infusion finishes

### 3. Worker Turtles (turtle.lua)
**Location:** Anywhere with GPS coverage
- **Any side:** Ender modem
- **GPS:** Required
- **Fuel:** Keep stocked with coal/charcoal

**Functions:**
- Scan pedestals around altars during setup
- Place catalyst and ingredients from chest onto pedestals
- Retrieve results and clear pedestals
- Deposit results into ME Interface

### 4. Client Monitor (client.lua)
**Location:** Any computer with a monitor
- **Any side:** Monitor (advanced recommended)
- **Any side:** Ender modem

**Functions:**
- Program new recipes
- View system status
- Monitor active infusions
- View recipe statistics

## Setup Instructions

### Step 1: Build Infusion Altars
1. Build your Thaumcraft infusion altar(s) as normal
2. Replace the block **directly below the catalyst pedestal** with a computer
3. Install `catalystpedestalcomputer.lua` on each computer
4. Attach an ender modem to each catalyst computer
5. Run the script - it will get GPS coords and register with the server

### Step 2: Setup Server
1. Place a computer with an **input chest on the RIGHT side**
2. Attach an ender modem on **top**
3. Make sure the ME Interface is accessible (same position as chest by default)
4. Install `server.lua`
5. Run the server - it will get GPS coords and wait for components

### Step 3: Deploy Turtles
1. Place turtle(s) in the area (at least 1 required)
2. Install `turtle.lua` on each
3. Attach ender modems
4. Ensure they have fuel (coal/charcoal)
5. Run the turtles - they will get GPS coords and register

### Step 4: Setup Monitor (Optional)
1. Place a computer with a monitor attached
2. Install `client.lua`
3. Run the client
4. Use the interface to program recipes and monitor status

### Step 5: Automatic Setup Phase
Once you have:
- ✅ Server running
- ✅ At least 1 catalyst pedestal computer running
- ✅ At least 1 turtle running

The system will automatically:
1. Server receives altar registrations from catalyst computers
2. Server assigns each altar to a turtle for pedestal scanning
3. Turtle visits each altar and scans for surrounding pedestals
4. Turtle reports pedestal positions back to server
5. Setup completes when all altars are scanned

You'll see "Setup Complete!" when ready.

## Programming Recipes

### Using the Monitor Client:
1. Put your desired catalyst + ingredients in the input chest
2. Switch to the "Program" tab on the monitor
3. Click "Catalyst" mode, then click the catalyst item
4. Click "Ingredient" mode, then click each ingredient
5. (Optional) Use "NBT/DMG" button to toggle matching rules
6. Click "ADD" to save the recipe

### Recipe Matching Rules:
- **matchNBT = true:** Item NBT data must match exactly
- **matchDMG = true:** Item damage value must match exactly
- Toggle these off if you want to match variations (e.g., any damage value)

## Running Infusions

1. Place catalyst + all ingredients in the input chest
2. System automatically detects matching recipe
3. System finds an available altar
4. Turtles place items on pedestals
5. Catalyst computer monitors for completion
6. When complete, turtles retrieve result and clear pedestals
7. Result is deposited into ME Interface

## Troubleshooting

### "Turtles not getting ID assignment"
- Make sure server is running first
- Check that turtles can get GPS position
- Verify ender modems are on the same wireless frequency
- Restart turtles after server is stable

### "Altar not registering"
- Ensure catalyst computer is **directly below** the pedestal
- Check that computer can wrap pedestal with `peripheral.wrap("top")`
- Verify GPS is working on the catalyst computer
- Check ender modem is attached and enabled

### "Setup never completes"
- Ensure at least 1 turtle is registered
- Check turtle has fuel
- Verify turtle can reach altar areas
- Look for turtle getting stuck or having path blocked

### "Infusion never detected as complete"
- Check catalyst computer is still running
- Verify pedestal can be wrapped as peripheral
- Make sure item actually changed on catalyst pedestal

### "Out of fuel"
- Keep coal in turtle inventory for auto-refuel
- System will attempt to get fuel from ME Interface if critical
- Make sure ME Interface position is correct

## File Descriptions

- **server.lua** - Main server (place on computer with chest on right)
- **catalystpedestalcomputer.lua** - Place on computer below EACH catalyst pedestal
- **turtle.lua** - Worker turtles (need at least 1)
- **client.lua** - Monitor interface (optional but recommended)

## Technical Details

### Communication Protocol
All components communicate on **channel 1742** using these message types:

**From Catalyst Computer:**
- `altar_register` - Registers altar location
- `infusion_complete` - Reports completed infusion

**From Turtle:**
- `turtle_register` - Registers with server
- `pedestals_scanned` - Reports pedestal positions found
- `turtle_task_complete` - Reports task completion
- `turtle_status_update` - Status changes

**From Server:**
- `altar_id_assigned` - Assigns ID to altar
- `turtle_id_assigned` - Assigns ID to turtle
- `scan_pedestals` - Orders turtle to scan an altar
- `turtle_tasks` - Assigns work tasks
- `infusion_started` - Notifies infusion beginning
- `setup_complete` - System ready

**From Client:**
- `add_recipe` - Submit new recipe
- `request_status` - Get system status
- `request_chest_contents` - Get chest inventory

### Database Persistence
Server saves to `itemdb.dat`:
- All programmed recipes
- Altar locations and pedestal configurations
- Recipe completion statistics

### GPS Requirements
- **Server:** Yes (once at startup)
- **Catalyst Computers:** Yes (once at startup)
- **Turtles:** Yes (initial + periodic checks)
- **Client:** No

### Coordinate System
All positions use GPS coordinates:
```lua
{x = number, y = number, z = number}
```

Turtles cache position and update after movement to reduce GPS calls.

## Limitations

- Lua 5.1 (no goto, continue, etc.)
- Requires GPS coverage in all altar areas
- Turtles need clear paths to altars and chest
- One recipe at a time per altar
- Server must remain running

## Future Enhancements

Possible improvements:
- Multiple simultaneous recipes
- Priority system for altars
- Better error recovery
- Glove turtle integration for essentia
- Web-based monitoring interface
- Automatic ingredient requesting from ME system

---

**Version:** 3.0  
**Last Updated:** February 2026  
**License:** Use freely, modify as needed!
