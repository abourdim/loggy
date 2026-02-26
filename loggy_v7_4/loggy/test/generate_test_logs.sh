#!/bin/bash
# generate_test_logs.sh — Creates synthetic log bundle for integration testing
# Generates logs that trigger ALL major detectors with known counts.
set -euo pipefail

OUTDIR="${1:-/home/claude/iotecha-log-analyzer/test/sample_logs/synthetic}"
mkdir -p "$OUTDIR"

TS="2026-01-15 10:00:00"
TS2="2026-01-15 10:05:00"
TS3="2026-01-15 10:10:00"

# ─── i2p2 / MQTT ───
cat > "$OUTDIR/i2p2app_combined.log" <<'EOF'
2026-01-15 10:00:01 [ERROR] MQTT connection failed: timeout
2026-01-15 10:00:05 [ERROR] MQTT connection failed: refused
2026-01-15 10:00:10 [INFO] MQTT connection OK: connected to endpoint
2026-01-15 10:00:15 [WARN] connection backoff 30s
2026-01-15 10:00:20 [WARN] connection backoff 60s
2026-01-15 10:00:25 [WARN] connection backoff 120s
EOF

# ─── NetworkBoss ───
cat > "$OUTDIR/NetworkBoss_combined.log" <<'EOF'
2026-01-15 10:00:01 [INFO] eth0 link up
2026-01-15 10:00:10 [WARN] eth0 link down
2026-01-15 10:00:15 [INFO] eth0 link up
2026-01-15 10:00:20 [WARN] eth0 link down
2026-01-15 10:00:25 [INFO] eth0 link up
2026-01-15 10:01:00 [WARN] NETWORK_NOT_FOUND: configured SSID not visible
2026-01-15 10:01:01 [WARN] NETWORK_NOT_FOUND: configured SSID not visible
2026-01-15 10:01:02 [WARN] NETWORK_NOT_FOUND: configured SSID not visible
2026-01-15 10:01:03 [WARN] NETWORK_NOT_FOUND: configured SSID not visible
2026-01-15 10:02:00 [WARN] CONN_FAILED: authentication failed
2026-01-15 10:02:01 [WARN] CONN_FAILED: authentication failed
2026-01-15 10:03:00 [INFO] ppp not configured, skip
EOF

# ─── OCPP ───
cat > "$OUTDIR/ocpp-cmd_combined.log" <<'EOF'
2026-01-15 10:00:01 [INFO] WebSocket connecting to wss://cs.example.com
2026-01-15 10:00:02 [ERROR] WebSocket connection failed
2026-01-15 10:00:05 [INFO] WebSocket connected
2026-01-15 10:00:10 [INFO] BootNotification sent
2026-01-15 10:00:11 [WARN] rejected: BootNotification isn't accepted yet
2026-01-15 10:00:20 [INFO] BootNotification Accepted
2026-01-15 10:00:30 [ERROR] OCPP_CONNECTION_ERROR raised
2026-01-15 10:01:00 [WARN] Offline queue: 15 messages pending
EOF

# ─── ChargerApp ───
cat > "$OUTDIR/ChargerApp_combined.log" <<'EOF'
2026-01-15 10:00:01 [INFO] Session started connector=1
2026-01-15 10:05:00 [INFO] Session completed connector=1
2026-01-15 10:10:00 [ERROR] CPState fault detected
2026-01-15 10:10:01 [ERROR] CPState fault detected
EOF

# ─── EnergyManager ───
cat > "$OUTDIR/EnergyManager_combined.log" <<'EOF'
2026-01-15 10:00:01 [INFO] EnergyManager started
2026-01-15 10:00:10 [ERROR] Direct queue not connected destination: ChargePoint_PMQ
2026-01-15 10:00:20 [ERROR] EM_start_session_error: Start session failed
2026-01-15 10:00:30 [WARN] No3phCurrentFlowDetectedIn3phBptSession
2026-01-15 10:01:00 [WARN] ENERGY_MANAGER_POWER_IMBALANCE_DETECTED
EOF

# ─── HealthMonitor ───
cat > "$OUTDIR/iotc-health-monitor_combined.log" <<'EOF'
2026-01-15 10:00:01 [INFO] Health monitor started
2026-01-15 10:00:05 [INFO] reboot count: 3
2026-01-15 10:00:10 [WARN] UnPlannedReboot detected, reboot reason: watchdog source: HealthMonitor type: Regular
2026-01-15 10:01:00 [WARN] StorageFallbackMode active
2026-01-15 10:02:00 [WARN] EmmcHighWearing detected EXT_CSD_PRE_EOL_INFO
2026-01-15 10:03:00 [WARN] FSSwitchToRO: /var/aux
2026-01-15 10:04:00 [ERROR] service down: ChargerApp
2026-01-15 10:05:00 [WARN] GPIO failure detected
EOF

# ─── Firmware / Monit / HMI ───
cat > "$OUTDIR/update-firmware_combined.log" <<'EOF'
2026-01-15 10:00:01 [ERROR] UpdateValidationFailedInvalidSignature
2026-01-15 10:00:02 [ERROR] UpdateValidationFailedInvalidChecksum
2026-01-15 10:01:00 [ERROR] PowerBoardFirmwareUpdateFailed
EOF

cat > "$OUTDIR/monit_combined.log" <<'EOF'
2026-01-15 10:00:01 [WARN] process restarted: ChargerApp
2026-01-15 10:00:02 [WARN] process restarted: i2p2app
2026-01-15 10:00:03 [WARN] process restarted: OCPP
2026-01-15 10:00:04 [WARN] process restarted: ChargerApp
2026-01-15 10:00:05 [WARN] ProcessRestartedTooOften: ChargerApp
2026-01-15 10:00:10 [WARN] HighCpuUsage detected
2026-01-15 10:00:11 [WARN] HighCpuUsage detected
2026-01-15 10:00:12 [WARN] HighCpuUsage detected
EOF

cat > "$OUTDIR/hmi-boss_combined.log" <<'EOF'
2026-01-15 10:00:01 [WARN] HMIBboardIsNotReady
2026-01-15 10:00:02 [WARN] HMIBboardIsNotReady
2026-01-15 10:00:05 [WARN] HMIBoardInitTimeout
EOF

# ─── V2G / HLC ───
cat > "$OUTDIR/evplccom_combined.log" <<'EOF'
2026-01-15 10:00:01 [ERROR] Error_PrechargeResTimeout
2026-01-15 10:00:02 [ERROR] Error_CableCheckResTimeout
2026-01-15 10:00:03 [ERROR] Error_CurrentDemandResTimeout
2026-01-15 10:00:10 [ERROR] Error_V2G_TCP_ConnectionClosed
2026-01-15 10:00:20 [ERROR] Error_PowerDeliveryStartTimeout
2026-01-15 10:00:30 [WARN] Error_Precharge_CarIsNotReadyForPowerDelivery
2026-01-15 10:00:40 [ERROR] Error_V2G_ExiDocProcessing
EOF

# ─── Safety ───
cat > "$OUTDIR/safety_combined.log" <<'EOF'
2026-01-15 10:00:01 [CRITICAL] EmergencyStop triggered
2026-01-15 10:00:02 [CRITICAL] ExternalEmergencyStop activated
2026-01-15 10:01:00 [CRITICAL] LidOpen detected
2026-01-15 10:01:01 [WARN] LidCloseWaitUnplug
2026-01-15 10:02:00 [ERROR] Temperature1Error
2026-01-15 10:02:01 [ERROR] OVERTEMPERATURE_1
2026-01-15 10:02:10 [WARN] DeratingApplied
2026-01-15 10:02:11 [WARN] DeratingApplied
2026-01-15 10:02:20 [CRITICAL] MaximalDeratingReached
EOF

# ─── Meter ───
cat > "$OUTDIR/iotc-meter-dispatcher_combined.log" <<'EOF'
2026-01-15 10:00:01 [ERROR] RequiredMeterMissing
2026-01-15 10:00:05 [WARN] RequiredMeterNotFound
2026-01-15 10:00:10 [WARN] DataUnavailable: reading registers failed
2026-01-15 10:00:15 [WARN] AutoDetectionFailed
2026-01-15 10:01:00 [ERROR] EICHRECHT_ERROR_STATE_TERMINAL
EOF

# ─── PowerBoard / HAL / InnerSM ───
cat > "$OUTDIR/powerboard_combined.log" <<'EOF'
2026-01-15 10:00:01 [CRITICAL] HARD_OVERCURRENT
2026-01-15 10:00:02 [CRITICAL] GROUND_FAULT
2026-01-15 10:00:03 [CRITICAL] BENDER_FAULT_1
2026-01-15 10:00:04 [CRITICAL] MAIN_RELAY1_STUCK_CLOSED
2026-01-15 10:00:05 [CRITICAL] PHASE_2_MISSING
2026-01-15 10:00:06 [CRITICAL] POWER_FAILURE
2026-01-15 10:00:10 [ERROR] ERROR_UNAVAILABLE: state machine exit
2026-01-15 10:00:11 [ERROR] CHARGING_CONFIRMATION_TIMEOUT
2026-01-15 10:00:12 [ERROR] ERROR_COMMUNICATION_BLOCKED
2026-01-15 10:00:20 [ERROR] CableCheckPreconditionIMDFailure
2026-01-15 10:00:21 [ERROR] RectifierConnectionFailed
2026-01-15 10:00:22 [ERROR] ContactorDidNotClose
2026-01-15 10:00:30 [ERROR] ErrorCIU_CriticalCommError
2026-01-15 10:00:31 [ERROR] ErrorMIU1_HeatsinkOverTempFault
2026-01-15 10:00:40 [WARN] EVDoesNotObeyImposedLimit
2026-01-15 10:00:41 [WARN] SoftOvercurrentDetected
2026-01-15 10:00:42 [WARN] MeterValuesNotReceived
2026-01-15 10:00:43 [WARN] MeterValuesNotReceived
2026-01-15 10:00:44 [WARN] MeterValuesNotReceived
2026-01-15 10:00:45 [WARN] MeterValuesNotReceived
EOF

# ─── CommonEVIC ───
cat > "$OUTDIR/commonevic_combined.log" <<'EOF'
2026-01-15 10:00:01 [WARN] Unintended Evic reboot detected
2026-01-15 10:00:10 [ERROR] CommonEVIC Reboot
EOF

# ─── CertManager ───
cat > "$OUTDIR/CertManager_combined.log" <<'EOF'
2026-01-15 10:00:01 [ERROR] Failed to read cert: ClientCertificate
2026-01-15 10:00:02 [ERROR] Failed to read cert: RootCA.pem
EOF

# ─── Kernel ───
cat > "$OUTDIR/kern.log" <<'EOF'
2026-01-15 10:00:01 kernel: [ERROR] oom-killer invoked
2026-01-15 10:00:02 kernel: [ERROR] driver timeout: modem
2026-01-15 10:00:03 kernel: [WARN] tpm tpm0: timeout
EOF

echo "✅ Synthetic logs generated in $OUTDIR"
echo "Files: $(ls -1 "$OUTDIR" | wc -l)"
ls -la "$OUTDIR"
