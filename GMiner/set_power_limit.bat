@echo off
title Set NVIDIA Power Limits

:: Set Power-Limits for your GPUs individually
:: GPU0
nvidia-smi -i GPU-<UUID> -pl 210
:: GPU1
nvidia-smi -i GPU-<UUID> -pl 210
