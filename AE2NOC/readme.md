AE2 Network Operations Center (NOC)

A high-tech monitoring and management suite for Applied Energistics 2, powered by ComputerCraft (CC: Tweaked). This system provides a centralized dashboard for stock levels, crafting history, storage capacity, and automated item maintenance.
📂 System Architecture

The NOC consists of three scripts working in tandem over a wireless network:
1. NOCDisplay.lua (The Brain)

    Role: The user interface and controller.

    Hardware: A Computer with a Wireless Modem and a large Multi-Block Monitor.

    Function: * Renders a 5-tab graphical interface.

        Handles touch input for adjusting stock levels.

        Processes data from the sensors to calculate real-time storage percentages.

2. mainSensor.lua

    Role: Data Aggregator.

    Hardware: A Computer connected to an AE2 Adapter or Interface.

    Function: * Scans the AE2 network for total item counts, active crafting jobs, and the translation queue.

        Broadcasts network state to the Display on channel 1428.

        Listens for SET_RULE commands from the Display to update auto-stocking targets.

3. cellSensor.lua

    Role: Storage Auditor.

    Hardware: A Computer connected to an AE2 Drive or Chest.

    Function: * Identifies the physical storage cells currently inserted (1k, 4k, 64k, etc.).

        Sends cell counts and types to the Display on channel 1422.

        Allows the UI to calculate "Bytes Usage" vs. "Max Capacity."

🖥️ Dashboard Tabs
Tab	Name	Description
1	OVERVIEW	System health, power status, and total item counts.
2	CRAFTING	Real-time monitoring of active CPU jobs and the translation scheduler.
3	STOCK	The "Command Center." Add/remove items from auto-stocking and adjust quantities.
4	HISTORY	A log of recently completed or failed crafting tasks with timestamps.
5	STORAGE	Visual progress bars for Byte/Type limits and a breakdown of physical drives.
📡 Networking & Setup
Channel Configuration

    1422: Storage Cell Data (Inbound to Display).

    1428: Network Statistics & History (Inbound to Display).

    1429: Control Commands (Outbound from Display to Main Sensor).

Installation

    Monitor Setup: Build a monitor (recommended 4x3) and attach a Wireless Modem to the Display computer.

    Peripherals: Ensure the mainSensor computer is touching an AE2 Interface/Adapter.

    Drive Specs: If using modded storage cells (e.g., Extra Cells), update the driveSpecs table in the Display script with the appropriate byte capacities.

🕹️ Controls (Tab 3: Stock Management)

    Select Item: Tap an item in the "Craftables" list (Right) or "Managed" list (Left).

    Manage/Unmanage: Use << to start managing an item or >> to stop.

    Adjust: Tap the green + or red - buttons to increase/decrease stock targets by 1, 10, 100, or 1000.
