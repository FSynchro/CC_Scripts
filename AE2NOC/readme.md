🌐 AE2 Network Operations Center (NOC)

A high-performance monitoring suite for Applied Energistics 2, designed for ComputerCraft: Tweaked. This system provides real-time visualization of storage capacity, item usage, and crafting CPU load across a multi-monitor display.
🏗️ System Architecture

The system is divided into three specialized nodes to ensure minimal lag and maximum data accuracy:

    Cell Sensor: Attached to a dedicated Storage Subnet to calculate the theoretical maximum capacity of your physical drives.

    Main Sensor: Attached to your primary AE2 network to track inventory totals, monitor crafting CPUs, and provide Yellorium fuel data to external systems.

    NOC Display: The central hub that aggregates all wireless data into a professional 2x3 monitor dashboard.

📡 Wireless Channel Map
Channel	Protocol	Sender	Receiver	Description
1422	Wireless	Cell Sensor	NOC Display	Physical Storage Cell inventory (for Capacity Math).
1428	Wireless	Main Sensor	NOC Display	Total item counts and Crafting CPU busy/idle states.
1425	Wireless	Main Sensor	Power Scripts	External Relay: Live Yellorium Ingot count for fuel monitoring.
📄 Script Breakdown
1. CellSensor.lua

    Connection: Place against an ME Interface. This interface should be part of a subnet that sees your ME Drives via Storage Buses.

    Function: Scans the available "items" (which are actually your Storage Cells) and transmits them to the NOC. This allows the system to know exactly how many 1k, 4k, 64k, etc., cells are installed.

2. MainSensor.lua

    Connection: Place against an ME Interface on your primary network.

    Function:

        Polls the network for total item counts and unique types.

        Monitors Crafting CPUs to detect system load.

        Fuel Provider: Specifically filters for Yellorium Ingots and broadcasts the count on a dedicated channel (1425) for reactor control scripts.

3. NOCDisplay.lua

    Connection: Connected to a 2x3 Advanced Monitor multiblock.

    Scale: Automatically sets text scale to 0.5 for high-density information.

    UI Features:

        Dash Tab: Shows progress bars for storage, a detailed breakdown of detected cell types, and a graphical 8x8 grid representing crafting CPU activity.

        Debug Tab: A diagnostic screen to monitor incoming wireless pulses and verify sensor health.

        Auto-Scaling: Automatically converts raw bytes into KB or MB for clean reading.

🛠️ In-Game Setup
Hardware Requirements

    3x Advanced Computers (with Wireless Modems).

    6x Advanced Monitors (arranged in a 2-wide, 3-high vertical stack).

    2x ME Interfaces.

Installation Steps

    Storage Subnet: Connect the Cell Sensor to an ME Interface that is looking at your ME Drives through Storage Buses. This ensures it sees the cells, not the items inside them.

    Primary Network: Connect the Main Sensor to your main AE2 network.

    The NOC: Place the NOC Display computer against your 2x3 monitor wall.

    Drive Specs: If using modded cells (like ExtraCells), verify the driveSpecs table in NOCDisplay.lua matches your modpack's capacities.

🖱️ Touch Controls

    [ 1: DASH ]: Primary overview of your AE2 Network.

    [ 2: DEBUG ]: View "Last Seen" timestamps for all sensors to troubleshoot wireless range issues.
