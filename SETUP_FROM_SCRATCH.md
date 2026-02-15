# Linux + Android Phone: Full Setup from Scratch (MAA + Arknights)

This guide configures one Linux PC and one Android phone to run MAA tasks end-to-end:
- startup
- infrast (custom 243 plan)
- award
- recruit
- mall
- fight (TA-9, expiring medicine)

The final automation entrypoint is:
- `/home/tian/ark/run_maa_infrast.sh`

## 1. Host requirements

Assumed host:
- Debian/Ubuntu-like Linux
- Docker available
- USB access to phone

Install required tools:
```bash
sudo apt update
sudo apt install -y docker.io docker-compose-plugin android-sdk-platform-tools scrcpy ffmpeg
```

Enable Docker service and current user access:
```bash
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

Re-login your shell session after adding docker group.

Check tools:
```bash
docker compose version
adb version
scrcpy --version
```

## 2. Prepare project directory

If project is not present yet:
```bash
mkdir -p /home/tian/ark
cd /home/tian/ark
```

Required structure after setup:
- `docker-compose.yml`
- `maa/Dockerfile`
- `maa/entrypoint.sh`
- `maa-config/profiles/default.toml`
- `maa-config/tasks/infrast.json`
- `maa-config/tasks/award.json`
- `maa-config/tasks/recruit.json`
- `maa-config/tasks/mall.json`
- `maa-config/infrast/243_4times_tbt20251104_noskip.json`
- `run_maa_infrast.sh`

## 3. Phone setup

On phone:
1. Enable Developer Options.
2. Enable USB debugging.
3. Disable lock screen password/pattern for stable automation.
4. Keep phone plugged in during runs.

Connect USB and accept "Allow USB debugging" dialog.

Verify on host:
```bash
adb devices
```
Expected:
```text
<serial>    device
```

Find serial and game package:
```bash
adb devices
adb -s <serial> shell pm list packages | grep -i arknights
```
Expected package:
- `com.hypergryph.arknights`

If game is not installed, install APK from legal source:
```bash
adb -s <serial> install /path/to/arknights.apk
```

## 4. Build MAA image

From `/home/tian/ark`:
```bash
docker compose build maa
```

Install/update Maa resources:
```bash
docker compose run --rm maa maa install
docker compose run --rm maa maa update
```

If update fails with ownership error on `MaaResource`, fix it once:
```bash
docker compose run --rm maa bash -lc "chown -R root:root /root/.local/share/maa/MaaResource"
docker compose run --rm maa maa update
```

## 5. Configure MAA profile

Edit `maa-config/profiles/default.toml`:
```toml
[connection]
preset = "ADB"
address = "RF8N316396H"
config = "General"
adb_path = "adb"

[instance_options]
adb_lite_enabled = false
deployment_with_pause = false
kill_adb_on_exit = false
touch_mode = "MaaTouch"
```

Change `address` to your actual serial from `adb devices`.

## 6. Configure tasks

### 6.1 Infrast (custom plan)

`maa-config/tasks/infrast.json`:
```json
{
  "tasks": [
    {
      "type": "Infrast",
      "params": {
        "facility": ["Mfg", "Trade", "Control", "Power", "Reception", "Office", "Dorm"],
        "drones": "Money",
        "custom": true,
        "filename": "243_4times_tbt20251104_noskip.json"
      }
    }
  ]
}
```

Place your custom plan file at:
- `maa-config/infrast/243_4times_tbt20251104_noskip.json`

### 6.2 Award

`maa-config/tasks/award.json`:
```json
{
  "tasks": [
    {
      "type": "Award",
      "params": {
        "award": true,
        "mail": true,
        "recruit": false,
        "orundum": false,
        "mining": false,
        "specialaccess": false
      }
    }
  ]
}
```

### 6.3 Recruit

`maa-config/tasks/recruit.json`:
```json
{
  "tasks": [
    {
      "type": "Recruit",
      "params": {
        "refresh": false,
        "select": [4],
        "confirm": [4, 3],
        "times": 4,
        "set_time": true,
        "expedite": false,
        "skip_robot": true,
        "server": "CN"
      }
    }
  ]
}
```

### 6.4 Mall

`maa-config/tasks/mall.json`:
```json
{
  "tasks": [
    {
      "type": "Mall",
      "params": {
        "visit_friends": true,
        "shopping": true,
        "buy_first": ["招聘许可", "龙门币"],
        "blacklist": ["家具零件"],
        "force_shopping_if_credit_full": false,
        "only_buy_discount": false,
        "reserve_max_credit": false,
        "credit_fight": false,
        "formation_index": 0
      }
    }
  ]
}
```

Note:
- Current MaaCore in this setup does not support standalone `type: "Visit"` task.
- Friend visit is handled by `mall.json` via `visit_friends: true`.

## 7. Validate each task before full run

Dry-run parser checks:
```bash
docker compose run --rm maa maa run award --dry-run -a RF8N316396H --batch
docker compose run --rm maa maa run recruit --dry-run -a RF8N316396H --batch
docker compose run --rm maa maa run mall --dry-run -a RF8N316396H --batch
docker compose run --rm maa maa run infrast --dry-run -a RF8N316396H --batch
docker compose run --rm maa maa fight TA-9 --dry-run -a RF8N316396H --expiring-medicine 99 --series 0 --batch
```

## 8. Run full automation once

```bash
/home/tian/ark/run_maa_infrast.sh
```

Current script behavior:
- acquires lock (`/tmp/run_maa_infrast.lock`) to avoid concurrent runs
- wakes and unlocks screen
- sets screen to 1080x1920 / density 480
- launches Arknights
- runs in order:
  1. startup
  2. infrast
  3. award
  4. recruit
  5. mall
  6. fight TA-9 with expiring medicine

Log file:
- `/home/tian/ark/maa-cron.log`

Live view:
```bash
tail -f /home/tian/ark/maa-cron.log
```

## 9. Add scheduled execution (cron)

Edit crontab:
```bash
crontab -e
```

Use:
```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOME=/home/tian

30 1 * * * /home/tian/ark/run_maa_infrast.sh
30 5 * * * /home/tian/ark/run_maa_infrast.sh
30 13 * * * /home/tian/ark/run_maa_infrast.sh
30 21 * * * /home/tian/ark/run_maa_infrast.sh
```

Verify:
```bash
crontab -l
```

## 10. Visual monitoring on phone

MAA has no GUI. Use scrcpy to watch phone actions:
```bash
scrcpy -s RF8N316396H
```

## 11. Troubleshooting

### 11.1 ADB shows offline / not found
```bash
adb kill-server
adb start-server
adb devices
```
Replug USB and re-authorize debugging on phone.

### 11.2 Script says `adb device not ready`
Phone not in `device` state. Check:
```bash
adb -s RF8N316396H get-state
```

### 11.3 Script exits after one failed task
This script continues through non-fatal steps and returns non-zero at end if any failed.
Inspect exact step rc in:
- `/home/tian/ark/maa-cron.log`

### 11.4 `unknown variant Visit`
Do not use standalone `Visit` task file with this MaaCore version.
Use:
- `mall.json` (`visit_friends: true`)
- `infrast` for clue-related operations.

### 11.5 `UnsupportedResolution`
Keep these pre-run settings in script:
- `wm size 1080x1920`
- `wm density 480`

### 11.6 scrcpy shared library error
If `scrcpy` fails with `libavdevice.so.*`, reinstall matching ffmpeg/scrcpy packages from your distro.

## 12. Daily operation checklist

1. Plug in phone.
2. Ensure phone is unlocked.
3. Confirm adb `device` state.
4. Run script manually or wait for cron.
5. Check `maa-cron.log` for each step rc.
