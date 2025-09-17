@echo off
setlocal ENABLEDELAYEDEXPANSION
title GMiner_GPU0

REM ====== Enter your UUID(s) here ======
set "UUID_LIST=GPU-[UUID1]"
REM Example for multiple:
REM set "UUID_LIST=GPU-[UUID1],GPU-[UUID2]"

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
miner.exe --algo kawpow --server rvn.2miners.com:6060 --user [YOUR_WALLET_ADDRESS].[YOUR_WORKER_ID] --devices %DEVICE_INDICES% --api 10050

echo [INFO] Mining ended
pause
