# Thaumcraft Infusion Automation System
## CC:Tweaked + Plethora Multi-Altar Automation

### Overview
This system automates Thaumcraft infusion crafting using ComputerCraft turtles with Plethora manipulators. It supports:
- Multiple infusion altars with automatic priority (closest first)
- Recipe programming via touchscreen monitor
- Automatic item detection and matching (with NBT/DMG options)
- Progress tracking and time estimation
- Disaster recovery for failed infusions
- AE2 integration for autocrafting

### Components

1. **Server Computer** (`server.lua`)
   - Manages recipes and coordinates turtles
   - Monitors chest for ingredients
   - Tracks infusion progress
   - Handles ME Interface integration

2. **Client Computer** (`client.lua`)
   - 2x3 Monitor interface
   - Two tabs: Status and Programming
   - Recipe configuration with visual feedback
   - Real-time progress bars

3. **Worker Turtles** (`turtle.lua`)
   - Minimum 3 turtles (1 catalyst, 2 ingredients)
   - Manipulator Mk II required
   - Wireless modem required
   - GPS-based navigation

### Setup Instructions

#### 1. GPS Setup
Before anything else, set up a GPS cluster:
- Place 4 computers at different Y levels around your base
- Run `gps host x y z` on each (where x,y,z are their coordinates)
- Test with `gps locate` on a turtle

#### 2. Server Computer Setup
```
Hardware:
- Advanced Computer
- Ender Modem (top)
- Input Chest (right side) - connected to ME Interface
- ME Interface (left side) - opposite of chest
```

Position the server near your infusion altar area. The ME Interface should output ingredients into the chest on the right side of the server.

#### 3. Client Computer Setup
```
Hardware:
- Advanced Computer
- Ender Modem
- 2x3 Monitor (any side)
```

Can be placed anywhere - it communicates wirelessly with the server.

#### 4. Turtle Setup
```
Hardware (each turtle):
- Advanced Turtle
- Wireless Modem
- Plethora Manipulator Mk II
```

Place 3+ turtles near the input chest. They will remember their starting position as "home".

#### 5. Infusion Altar Setup
```
Required:
- Thaumcraft Infusion Matrix (center)
- Runic Matrix (below center pedestal)
- Pedestals arranged in standard pattern
- Place Mana Infused Metal Block (thermalfoundation:storage:8) BELOW each catalyst pedestal
```

The system will auto-discover altars by scanning for the Mana Infused Metal blocks!

### Pedestal Layout
```
  9  1  11
5         7
          
3    C    4
          
8         6
  12 2  10

C = Catalyst pedestal (Mana Infused Metal below)
Numbers = Ingredient pedestals
```

### Usage

#### Programming a Recipe:
1. Put items in the input chest
2. Switch to "Programming" tab on client monitor
3. Click on an item, then click "Cat" to mark as catalyst (yellow)
4. Click on ingredients, then click "Ing" to mark (green)
5. Use "NBT/DMG" button to toggle matching:
   - Yellow border = NBT matching OFF
   - Orange border = DMG matching OFF  
   - Red border = Both OFF
6. Click "ADD" to save recipe

#### Running Infusions:
1. Server auto-detects when chest contains a known recipe
2. Turtles automatically place items on pedestals
3. Watch progress on Status tab
4. Result automatically returns to ME Interface

### Channel Configuration
All devices use channel **1742**
- Change CHANNEL variable at top of each file if needed

### Database
Recipes are saved to `itemdb.dat` on the server and persist across restarts.

### Error Handling
- If infusion takes 3x longer than expected: enters error mode
- "RESET" button on client clears error state
- Turtles will abort and return home on disaster

### Troubleshooting

**"No modem found"**
- Attach ender modem to computer/turtle

**"ME Interface not found on LEFT side"**
- Place ME Interface opposite the input chest from server

**"Cannot get GPS position"**
- Ensure GPS hosts are running
- Check you're in range of GPS cluster

**Turtles not moving**
- Check fuel levels
- Verify GPS is working (`gps locate`)
- Check wireless modem is attached

**Items not transferring**
- Verify Manipulator Mk II is installed
- Check chest/pedestal positions

### Future Features (Commented Out)
- Golem automation via glove chest system
- Redstone signaling for infusion start
- Stability monitoring

### Files
- `server.lua` - Main server program
- `client.lua` - Monitor interface
- `turtle.lua` - Worker turtle program
- `itemdb.dat` - Recipe database (auto-generated)

### Credits
System designed for Minecraft 1.12.2 with:
- ComputerCraft: Tweaked
- Plethora Peripherals
- Thaumcraft 6
- Thaumtweaks (for golem infusion starting)
- Applied Energistics 2
- Thermal Foundation
