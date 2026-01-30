🔋 PWRCTRL: Reactor Management System

The PWRCTRL suite is a professional-grade power management system designed for Extreme Reactors. It features a "Brain" server that manages the physical reactor hardware and a high-fidelity touch-screen "Client" for remote operations and diagnostic visualization.
🏗️ System Architecture

The power system operates on a dedicated wireless frequency, communicating with the NOC Main Sensor to keep track of fuel reserves while controlling the reactor's physical state.

    EMS Server: Connects physically to the Reactor and Energy Storage.

    EMS Client: Connects to an Advanced Monitor for touch control.

    Fuel Subscriber: Listens to the NOC's broadcast for live Yellorium tracking.

📡 Wireless Channel Map
Channel	Direction	Script	Description
4335	BIDI	Server <-> Client	Syncs Reactor stats (DATA) and remote commands (CMD).
1425	IN	Client	Subscribes to the NOC's Yellorium Ingot broadcast.
📄 Script Breakdown
1. PowerCTRLWirServer.lua (The "Brain")

    Hardware: Wired Modem connected to a Reactor Computer Port and Energy Cells.

    Core Logic:

        Dampened Rod Control: In "Auto" mode, it moves control rods by 1% per update. This prevents the battery from "bouncing" between 0% and 100% and maintains steady steam/power output.

        Emergency Overdrive: If battery levels drop below 5%, the server forces rods to 0% (Maximum Output) to prevent a total blackout.

        Energy Flow Analysis: Calculates if the grid is charging, discharging, or stable.

2. PowerCTRLWirClient.lua (The "Interface")

    Hardware: Advanced Monitor (arranged in a standard landscape or portrait configuration).

    UI Features:

        Reactor View:

            Live Animation: An ASCII core that pulses when the reactor is active.

            Diagnostic Bars: Vertical visualizers for Control Rod depth and Battery percentage.

            Fuel Counter: Live display of Yellorium Ingots, relayed directly from the NOC sensors.

        Modem View: A real-time traffic log showing every packet sent and received on the network.

        Touch Controls: Toggle Auto-Rod logic or manually force the reactor ON/OFF.

🎮 Operational Modes

    AUTO-RODS (ON): The server manages rod depth based on power demand. Rods will insert as the battery fills and retract as it empties.

    AUTO-RODS (OFF): Rods stay at their current position. Manual toggling of the Reactor (ENABLE/DISABLE) is still available.

    OVERDRIVE: An automatic state triggered at low power that overrides efficiency to prioritize grid recovery.

🛠️ Configuration

    Update Rate: Found in the Server script (updateRate = 2). Adjust this to change how quickly the rod dampening logic reacts.

    Smooth Rod Math: The server is tuned for a "sweet spot" between 15% and 85% battery. You can modify the getSmoothRodLevel function to change how aggressively the reactor throttles.
