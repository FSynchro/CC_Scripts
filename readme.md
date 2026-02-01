🌌 Integrated Base Management System

A high-performance automation suite for Applied Energistics 2 and Extreme Reactors. This system uses a decentralized sensor-hub architecture to provide real-time base telemetry with zero interface lag.
📂 Project Structure

The system is split into two primary modules. Each handles a critical part of your base infrastructure and shares data wirelessly for a unified overview.
1. AE2NOC

Role: Storage, Crafting, and Resource Sensing.

    Capabilities: 2x3 Monitor Dashboard, theoretical capacity math (Bytes/Types), and a 64-pixel graphical crafting load grid. Acts as the "Main Sensor" for the entire network.

2. PowerCTRL

Role: Intelligent Reactor Automation & UI.

    Capabilities: Dampened rod control for fuel efficiency, remote touch-screen operation, and live Yellorium tracking via the NOC sensor relay.

📡 Wireless Communication Map

The system uses a wireless mesh to synchronize data between sensors, the NOC hub, and the Reactor controls:
Channel	Traffic Flow	Description
1422	Cell Sensor ➔ NOC	Raw physical drive data for capacity math.
1428	Main Sensor ➔ NOC	Total item counts and Crafting CPU states.
1425	Main Sensor ➔ Power	Relay: Broadcasts Yellorium counts for fuel tracking.
4335	Power Server ➔ Client	Reactor telemetry and remote command sync.
🛠️ Installation

You can install the entire suite directly onto your in-game computers using the following commands:
Bash

# 1. Download the clone utility
wget https://gist.githubusercontent.com/SquidDev/e0f82765bfdefd48b0b15a5c06c0603b/raw/clone.min.lua

# 2. Clone the repository
clone.min https://github.com/FSynchro/CC_Scripts

⚙️ Setting Up Auto-Start (startup.lua)

RUN CC_Sripts/startupmaker, it'll allow you to select the script you want to automatically start, it will create a startup.lua


📋 Requirements

    Applied Energistics 2: ME Interfaces (for sensors) and Storage Buses (for the Cell subnet).

    Extreme Reactors: Reactor Computer Port.

    Peripherals: Wireless Modems on all computers; Advanced Monitors for display nodes.
