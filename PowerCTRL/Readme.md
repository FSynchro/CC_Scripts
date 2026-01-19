Energy Maintenance System (EMS) for ComputerCraft

A robust, storage-agnostic reactor management and energy monitoring suite designed for Extreme Reactors and Thermal Expansion (and other RF-compatible mods).

This script provides a high-fidelity dashboard for monitoring power grids, automating fuel efficiency via control rod insertion, and providing manual safety overrides.
🚀 Features

    Agnostic Grid Discovery: Automatically detects and aggregates all connected energy storage devices into a single "Total Grid" capacity.

    Intelligent Auto-Management: * > 80% Storage: Inserts rods to 100% (Standby) to halt fuel consumption.

        < 30% Storage: Sets rods to 90% (Efficient Burn) for steady recovery.

        Normal Ops: Maintains 50% insertion for balanced output.

    Dynamic UI Scaling: Automatically detects monitor dimensions and adjusts text scale and layout for 2x4, 3x6, or custom monitor walls.

    Visual Rod Telemetry: A dedicated "taller" ASCII rod display that changes colors based on insertion depth (Green for active, Yellow/Red for high insertion).

    Interactive Controls: Touch-screen support for toggling automation and a dedicated "Disable Reactor" safety button.

🛠 Hardware Requirements

    Computer: Advanced Computer (for color support).

    Monitor: Any size (Advanced Monitors recommended).

    Wired Modems & Networking: * Connect to a Reactor Computer Port.

        Connect to any Energy Cell (Thermal Expansion) or Power Tap.

    Peripheral Names: The script looks for peripherals containing:

        BigReactors-Reactor

        storage_cell (Thermal Expansion)

        energy (Generic)

📥 Installation

    Ensure your modems are active (right-click them so they glow red).

    Run the following command on your in-game computer:
    Bash

    edit ems.lua

    Paste the script and save.

    Run the script:
    Bash

    ems.lua

🎮 Interface Guide
Section	Description
Energy Status	Shows if the grid is Charging, Discharging, or Stable.
Automanage CTRL Rods	Interactive toggle. When [ ON ], the computer handles fuel efficiency.
Rod Insertion	Real-time percentage of how deep the rods are inside the core.
Reactor Status	Displays active (burning fuel) or inactive (shutdown).
Storage %	A vertical battery bar representing the entire grid's health.
[ DISABLE REACTOR ]	Emergency button. Shuts down the core and kills the automation script.
⚙️ Configuration

The script is designed to be plug-and-play. However, you can adjust the refreshRate at the top of the file to change how often the computer pings the server (default is 1 second for low-lag operation).

Would you like me to add a "Changelog" section or a specific "Troubleshooting" section for common modem connection issues to this README?
