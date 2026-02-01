# 🌌 FSYNC: Integrated Base Management System

A high-performance, decentralized automation suite for **Applied Energistics 2** and **Extreme Reactors**. FSYNC utilizes a "Sensor-to-NOC" architecture to provide real-time base telemetry with zero interface lag and multi-terminal support.


## 📂 Project Structure

The system is split into specialized modules that communicate over a unified wireless mesh.

### 1. AE2NOC (`/CC_Scripts/AE2NOC`)
* **MainSensor.lua**: The brain of the AE2 network. Scans item counts and Crafting CPU states.
* **CellSensor.lua**: Monitors the physical storage subnet. Tracks drive sizes to calculate raw Byte/Type limits.
* **NOCDisplay.lua**: The client-side UI. Features a 5-tab dashboard including real-time "Available" storage math and a 64-pixel crafting load grid.

### 2. PowerCTRL (`/CC_Scripts/PowerCTRL`)
* Intelligent Reactor automation with dampened rod control for maximum fuel efficiency.
* Remote touch-screen operation and live Yellorium tracking via the NOC relay.

---

## 📡 Wireless Communication Map

FSYNC uses a synchronized frequency map to ensure data integrity across all nodes:

| Channel | Traffic Flow | Description |
| :--- | :--- | :--- |
| **1422** | Cell Sensor ➔ NOC | Raw physical drive data (Max Bytes/Types). |
| **1428** | Main Sensor ➔ NOC | Live item counts and Crafting CPU states. |
| **1425** | Main Sensor ➔ Power | Relay: Broadcasts fuel counts for reactor logic. |
| **4335** | Power Server ➔ Client | Reactor telemetry and remote command sync. |

---

## 🛠️ Installation & Deployment

### 1. Fast Clone
Run these commands on any Advanced Computer with a Wireless Modem:

```bash
wget [https://gist.githubusercontent.com/SquidDev/e0f82765bfdefd48b0b15a5c06c0603b/raw/clone.min.lua](https://gist.githubusercontent.com/SquidDev/e0f82765bfdefd48b0b15a5c06c0603b/raw/clone.min.lua)
lua clone.min.lua [https://github.com/FSynchro/CC_Scripts](https://github.com/FSynchro/CC_Scripts)
