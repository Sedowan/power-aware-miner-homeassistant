# Smart Power-Aware Mining Rig with Home Assistant and Windows

This project describes a fully automated mining rig that operates GPUs based on surplus solar power. The setup combines:

- A **Windows 11 mining rig** with NVIDIA GPUs and GMiner
- **HASS.Agent** for command/control and monitoring
- **Home Assistant** for solar-aware logic and automation

> The system ensures that mining only occurs when conditions allow, such as sufficient battery charge, available photovoltaic (PV) power, and low competing load priority.

> The example is based on 6 available GPUs. However, the logic is repetitive.

---

## Step 1: Mining Rig Setup (Windows 11)

The mining rig runs **Windows 11** and uses **GMiner** for mining (e.g., Ravencoin). It includes one `.bat` file per GPU and is controlled externally via Home Assistant.

### Folder Structure

All files are placed inside:

```
C:\Mining\GMiner\
├── miner.exe
├── mine_ravencoin_0.bat
├── mine_ravencoin_1.bat
├── ...
├── mine_ravencoin_x.bat
├── set_power_limit.bat
```

### Setting GPU Power Limits at Boot

To ensure GPUs always run with the correct power limits, the file `set_power_limit.bat` is executed during system startup using Windows Task Scheduler. This batch script applies power limits via `nvidia-smi` and GPU UUIDs.

#### Example: `set_power_limit.bat`

```bat
@echo off
title Set NVIDIA Power Limits
:: GPU0
nvidia-smi -i GPU-<UUID> -pl 210
:: GPU1
nvidia-smi -i GPU-<UUID> -pl 210
```

#### Registering the Task at Boot

Run this one-liner in an elevated Command Prompt:

```bat
schtasks /create /tn "SetNvidiaPL" /tr "C:\Mining\set_power_limit.bat" /sc onstart /ru "SYSTEM" /rl HIGHEST
```

#### Verify Settings

```bat
nvidia-smi --query-gpu=name,power.limit --format=csv
```

### Batch Files for Mining

Each GPU is controlled via its own `.bat` file. They define the miner executable, pool, wallet, and device index.

#### Sample: `mine_ravencoin_sample.bat`

```bat
title GMiner_GPU<ID>
cd "C:\Mining\GMiner\"
miner.exe --algo kawpow --server [YOUR_POOL_ADDRESS] --user [YOUR_WALLET].[YOUR_WORKER_ID] --devices GPU<ID>
pause
```

- Each file uses a distinct `--devices` number and `title` for tracking
- All batch files remain in the miner directory

For advanced setups, the GPU `UUID` can be mapped to GMiner indices. This ensures deterministic GPU selection when multiple models are present.

#### Example: `mine_ravencoin_0.bat`

```bat
@echo off
setlocal ENABLEDELAYEDEXPANSION
title GMiner_GPU0

REM ====== Enter your UUID(s) here ======
set "UUID_LIST=GPU-<UUID1>"
REM Example for multiple:
REM set "UUID_LIST=GPU-<UUID1>,GPU-<UUID2>"

set "DEVICE_INDICES="

REM ====== UUID -> INDEX mapping for 'nvidia-smi -L' ======
for %%U in (%UUID_LIST%) do (
  set "IDX_FOUND="
  for /f "usebackq tokens=2 delims= " %%I in (`
    nvidia-smi -L 2^>nul ^| find "%%~U"
  `) do (
    set "IDX_TMP=%%I"
    set "IDX_FOUND=!IDX_TMP::=!"
  )
  if defined IDX_FOUND (
    if defined DEVICE_INDICES (
      set "DEVICE_INDICES=!DEVICE_INDICES!,!IDX_FOUND!"
    ) else (
      set "DEVICE_INDICES=!IDX_FOUND!"
    )
  ) else (
    echo [ERROR] UUID %%~U could not be found
    echo [DEBUG]output of 'nvidia-smi -L':
    nvidia-smi -L
    pause
    exit /b 1
  )
)

echo [INFO] UUID(s): %UUID_LIST%
echo [INFO] GMiner-Indices: %DEVICE_INDICES%

REM ====== Overview and check ======
nvidia-smi -L
nvidia-smi --query-gpu=index,uuid,name,pci.bus_id --format=csv 2>nul

REM ====== Start GMiner ======
cd /d C:\Mining\GMiner
miner.exe --algo kawpow --server rvn.2miners.com:6060 --user [YOUR_WALLET_ADDRESS].[YOUR_WORKER_ID] --devices %DEVICE_INDICES%

echo [INFO] Mining ended
pause
```

---

## Step 2: HASS.Agent Integration on Windows Rig

### Access Configuration

- A **long-lived access token** is created in Home Assistant and entered into HASS.Agent
- MQTT uses existing `mosquitto` broker credentials
- Ensure all commands and sensors run with **"Run as low integrity"** enabled

### Commands Setup (from `commands.json`)

Each GPU has its own start/stop command in HASS.Agent.

#### Start GPU0:

```json
{
  "Name": "Mining-Rig-1-Start-GPU0",
  "Command": "C:\\Mining\\GMiner\\mine_ravencoin_0.bat",
  "RunAsLowIntegrity": true
}
```

#### Stop GPU0:

```json
{
  "Name": "Mining-Rig-1-Stop-GPU0",
  "Command": "taskkill /f /fi \"WindowTitle eq  GMiner_GPU0\" /t",
  "RunAsLowIntegrity": true
}
```

The same pattern is used for GPU1 through GPU5, with only the device number and window title changing.

#### Graphical Setup Examples:

**Start GPU0 Command Setup**

![GPU_Start_Command](images/gpu_start_bat_en.jpg)


This shows how HASS.Agent is configured to start GPU0 by executing the batch file `mine_ravencoin_0.bat`. The "Run with low integrity" option is checked to allow execution without elevated privileges.

**Stop GPU0 Command Setup**

![GPU_Stop_Command](images/killtask_en.jpg)

This shows the HASS.Agent stop command for GPU0, which uses a `taskkill` command targeting the window title of the GPU miner process.

---

## Step 3: GPU Status Monitoring via HASS.Agent Sensors

### Active Window Detection (from `sensors.json`)

Each GPU has a `NamedWindowSensor` to detect whether the corresponding miner process is running.

#### Example: GPU0

```json
{
  "Type": "NamedWindowSensor",
  "Name": "GMiner_GPU0_active",
  "WindowName": "GMiner_GPU0",
  "UpdateInterval": 5
}
```

These sensors are auto-discovered in Home Assistant as `binary_sensor.mining_rig_1_gminer_gpux_active`.

#### Graphical Setup Example:

![HASS.Agent_Sensor](images/sensor1_en.jpg)

This shows the sensor configuration in HASS.Agent. It tracks if a Command Prompt window with the title `GMiner_GPU0` is open (not necessarily in focus).

### Power Limit Tracking (from `sensors.json`)

Each GPU has a `PowershellSensor` to detect current power limit of that GPU.

#### Example: GPU0

```json
  {
    "Type": "PowershellSensor",
    "Id": "<UUID>",
    "Name": "GPU_powerlimit_<graphic-card>",
    "UpdateInterval": 60,
    "Query": "(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits -i GPU-<UUID>).Trim()",
    "Scope": null,
    "WindowName": "",
    "Category": "",
    "Counter": "",
    "Instance": "",
    "EntityName": "GPU_powerlimit_<graphic-card>",
    "IgnoreAvailability": true,
    "ApplyRounding": false,
    "Round": null,
    "AdvancedSettings": null
  },
```

These sensors are auto-discovered in Home Assistant as `sensor.GPU_powerlimit_<graphic-card>`.

#### Graphical Setup Example:

![HASS.Agent_Sensor](images/sensor2_en.jpg)

This shows the sensor configuration in HASS.Agent.


### Final HASS.Agent Setup:

![HASS.AGENT_Sensors](images/sensors_en.jpg)

This shows the sensors configuration in HASS.Agent after the setup.



![HASS.AGENT_Commands](images/commands_en.jpg)

This shows the commands configuration in HASS.Agent after the setup.



![HA_MQTT_Commands_and_Sensors](images/HA_MQTT_Entities_de.jpg)

This shows the commands and sensors configuration in Home Assistant after the setup.

---

## Step 4: Power Logic Calculation in Home Assistant

Two Home Assistant template sensors determine system capability:

The first sensor (`possible_gpus`) calculates how many GPUs can be powered based on grid power, solar power, battery SOC, and the status of a priority consumer. If conditions are favorable, it estimates how many GPUs could be run without drawing energy from the grid.

The second sensor (`active_gpus`) simply counts how many GPUs are currently active, using HASS.Agent window sensors that detect running miner windows.

By comparing both values, the system can decide when to start or stop mining GPUs.

Replace (`[YOUR_...]`) with the appropriate value of your system.

### Sensor: `possible_gpus`

```yaml
- sensor:
    - name: "possible_gpus"
      unique_id: bf167e5d-3257-46fe-9363-c5214fab5989
      icon: mdi:expansion-card
      state: >
        {% set gpus = int(0) %}
        {% set possible_g = states('sensor.possible_gpus') | int(0) %}
        {% set grid_p = states('sensor.[YOUR_GRID_SENSOR]') | float(0) %}
        {% set active_g = states('sensor.active_gpus') | int(-10) %}
        {% set prio_p = states('sensor.[YOUR_PRIORITY_CONSUMER]') | float(0) %}
        {% set prio_on = states('switch.[YOUR_PRIOTITY_CONSUMER_SWITCH_STATE]')  | bool(true) %}
        {% set pv_p = states('sensor.[YOUR_SOLAR_POWER]') | float(0) %}
        {% set soc_v = states('sensor.[YOUR_STATE_OF_CHARGE]') | float(0) %}
        {% set max_gpus = int([YOUR_GPU_NUMBER]) %}
        {% set est_p_gpu = [YOUR_ESTIMATED_POWER_DRAW_PERGPU] %}
        {% set est_p_prio = [YOUR_ESTIMATED_POWER_DRAW_PRIO] %}
        {% set lower_soc = [YOUR_LOWER_SOC_LIMIT] %}
        {% set surp_th_g = [YOUR_SURPLUS_THRESHOLD_FOR_GRID] %}
        {% set surp_th_p = [YOUR_SURPLUS_THRESHOLD_FOR_PRIORITY] %}
        {% if active_g >= 0 %}
          {% set grid_p_wo_gpu = float(grid_p + (float(active_g) * est_p_gpu)) %}
        {% endif %}
        {% if grid_p > 0 %}
          {% if pv_p > 0 %}
            {% if prio_on == false and grid_p_wo_gpu > surp_th_g and grid_p_wo_gpu < 1850 and soc_v > lower_soc %}
              {% set gpus = int(grid_p_wo_gpu / est_p_gpu ) | round(0) %}
            {% elif prio_on == true and grid_p_wo_gpu > surp_th_g and soc_v > lower_soc %}
              {% set gpus = int((grid_p_wo_gpu) / est_p_gpu ) | round(0) %}
            {% elif prio_on == false and grid_p_wo_gpu > est_p_prio and soc_v > lower_soc %}
              {% set gpus = int((grid_p_wo_gpu - prio_p - surp_th_p) / est_p_gpu ) | round(0) %}
            {% else %}
              {% set gpus = 0 %}
            {% endif %}
          {% else %}
            {% set gpus = 0 %}
          {% endif %}
        {% else %}
            {% set gpus = 0 %}
        {% endif %}
        {% if gpus > max_gpus %}
          {% set gpus = max_gpus %}
        {% endif%}
        {{ gpus }}
```

### Sensor: `active_gpus`

```yaml
- sensor:
    - name: "active_gpus"
      unique_id: cfadd[YOUR_LOWER_SOC_LIMIT]6-b245-4e1c-a0af-7a890e83dcdd
      icon: mdi:expansion-card-variant
      state: >
        {% set gpu0 = int(1) %}
        {% set gpu1 = int(1) %}
        {% set gpu2 = int(1) %}
        {% set gpu3 = int(1) %}
        {% set gpu4 = int(1) %}
        {% set gpu5 = int(1) %}
        {% set gpus = int(6) %}
        {% if states('binary_sensor.mining_rig_1_gminer_gpu0_active') == "off" %}
          {% set gpu0 = int(0) %}
        {% endif %}
        {% if states('binary_sensor.mining_rig_1_gminer_gpu1_active') == "off" %}
          {% set gpu1 = int(0) %}
        {% endif %}
        {% if states('binary_sensor.mining_rig_1_gminer_gpu2_active') == "off" %}
          {% set gpu2 = int(0) %}
        {% endif %}
        {% if states('binary_sensor.mining_rig_1_gminer_gpu3_active') == "off" %}
          {% set gpu3 = int(0) %}
        {% endif %}
        {% if states('binary_sensor.mining_rig_1_gminer_gpu4_active') == "off" %}
          {% set gpu4 = int(0) %}
        {% endif %}
        {% if states('binary_sensor.mining_rig_1_gminer_gpu5_active') == "off" %}
          {% set gpu5 = int(0) %}
        {% endif %}
        {% set gpus = int(gpu0 + gpu1 + gpu2 + gpu3 + gpu4 + gpu5) %}
        {{ gpus }}
```

---

## Step 5: Automation – Dynamic GPU Start/Stop

This automation starts or stops mining GPUs depending on the comparison of `possible_gpus` and `active_gpus`.

```yaml
alias: Miningmanagement
```
[... see automations.yaml ...]
![automations.yaml](HomeAssistant/automations.yaml)

> ⚠️ The full action block includes one-by-one conditional logic for each GPU, using `button.press` and 15-second delays between steps.

---

## Summary

This project allows:

- Automated, energy-efficient GPU mining
- Tight integration with real-time PV and battery metrics
- Granular GPU control and feedback
- Fully modular and reproducible setup

This project is "as is" and will not be maintained.

---

Feel free to fork and customize the logic, or open issues for improvements or questions.

## Credits

- [Home Assistant](https://www.home-assistant.io/)
- [HASS.Agent](https://github.com/LAB02-Research/HASS.Agent)
- [ChatGPT](https://ChatGPT.com)