CC_Scripts: Integrated Energy & Storage Management

A suite of ComputerCraft (CC: Tweaked) scripts designed to provide real-time monitoring and automation for Extreme Reactors and Applied Energistics 2 (AE2) networks.


Installation

You can install these scripts directly onto your in-game computers using the following commands:


```

wget https://gist.githubusercontent.com/SquidDev/e0f82765bfdefd48b0b15a5c06c0603b/raw/clone.min.lua

clone.min https://github.com/FSynchro/CC_Scripts

```

🏗️ System Architecture

The system consists of four primary scripts distributed across 4 or more computers:

 Reactor Server: Manages the physical Reactor and power storage.

AE2 Hub: A two-part system that monitors ME storage and calculates drive capacities. 
(You'll need 2 AE networks that we can read the contents through ME interfaces, the network that has all the storage Cells and the network that reads the contents of the drives, an example architecture can be seen below.)

Control Client: A central "NOC" (Network Operations Center) that displays all data on a large monitor and allows for remote reactor control.

Here's an example architecture for this entire setup:

```
AE2 setup:

                           ME drive|Storage Bus< - - - > ME Controller [Storage cell subnet] -------> ME Interface|MODEM>=========<MODEM|Computer(Ae2Stordrives.lua)|WirelessModem>
                             |
                             |
                             |
 [Optional] Me controller to connect more ME drives for bigger storage network
                             |
                             |
                             |
                             V
                        ME Interface
                             ^
                        Storage BUS
   (We read the ME interface's contents here with the storage bus
   meaning we will read the contents of what is stored in the drives
                in the Storage Cell Subnet)
                             |
                             |
                             |                                                                      =====<MODEM|AdvancedMonitor (for displaying AE2 storage data)
                             V                                                                      =
                        ME Controller [Contents of Storage cel subnet) -----> ME Interface|MODEM>========<MODEM|Computer(Ae2StorMonitor.lua)|WirelessModem>
                             ^
                             |
                        ME Crafting Terminal


Reactor setup:

Big Reactor computer Port|MODEM>====<MODEM|Computer(PWRCTRLWirServer.lua)|Wirelessmodem>

<Wirelessmodem|Computer(PWRCTRLWirClient.lua)|Modem>=======<Modem|AdvancedMonitor (for displaying/controlling reactor status and yellorium ingots stored in AE2)



- = fluix cable
= = CC network cable


```
<img width="1924" height="1041" alt="image" src="https://github.com/user-attachments/assets/73428d02-fd3d-4cc6-a489-935cf5d176e0" />



📄 Script Overview
1. PowerCTRLWirServer.lua

Role: The "Brain" of the power plant.

    Hardware: Connect directly to a Reactor (Extreme Reactors) and Energy Cells/Capacitors. Requires a Wireless Modem.

    Features:

        Dampened Rod Control: Automatically adjusts control rods based on battery percentage to prevent "bouncing" and maximize fuel efficiency.

        Overdrive Mode: Detects critical power failure (<5%) and forces maximum output.

        Wireless API: Broadcasts status data on Channel 4335 and listens for remote commands (ON/OFF/AUTO).

2. PowerCTRLWirClient.lua

Role: The User Interface.

    Hardware: Advanced Computer with an Advanced Monitor attached.

    Features:

        Dual-View System: Toggle between [REACTOR] status and [MODEM] traffic logs.

        Touch Controls: Enable/Disable the reactor or toggle Auto-Rod logic via the monitor.

        Diagnostics: Visualizes battery levels, control rod depth, and Yellorium Ingot counts pulled from the AE2 network.

        Live Animation: Dynamic ASCII art showing reactor core activity.

3. AE2StorMonitor.lua

Role: The AE2 Dashboard.

    Hardware: Attached to an ME Interface and an Advanced Monitor.

    Features:

        Inventory Scanning: Scans the network for bigreactors:ingotyellorium.

        Broadcasting: Transmits the fuel count to the Power Client on Channel 1425.

        Local Display: Shows a breakdown of total bytes used, unique item types, and a list of detected storage cells.

4. AE2StorDrives.lua

Role: Capacity Calculator.

    Hardware: Attached to the same ME Interface as the Monitor.

    Features:

        Drive Specs: Contains a database of storage capacities for 1k, 4k, 16k, and 64k cells (including ExtraCells support).

        Real-time Math: Calculates the theoretical maximum byte/type capacity of the network and sends it to the Monitor script via Channel 1422.

📡 Wireless Channel Map
Channel	Sender	Receiver	Description
4335	Server	Client	Reactor Stats & Remote Commands
1422	Drives	Monitor	Max Capacity & Drive Count Data
1425	Monitor	Client	Yellorium Ingot Count (AE2 -> Power)
🛠️ Configuration

To customize your setup, look for these variables at the top of the scripts:

    channel: Change this if you have multiple reactor setups nearby.

    updateRate: Adjust how often the server pulses data (default 2s).

    target: In the Server script, you can adjust the math inside getSmoothRodLevel to change at what battery % the reactor starts throttling.








Screenshots:

<img width="1027" height="608" alt="image" src="https://github.com/user-attachments/assets/3d986505-a225-4f0a-aa49-ef2153b63d3c" />

<img width="1330" height="828" alt="image" src="https://github.com/user-attachments/assets/cb26ec29-e574-43fb-b395-ce2d9aa43049" />


