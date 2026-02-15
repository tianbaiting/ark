# 明日方舟 + MAA（手机 ADB / redroid）操作手册

本目录用于用 MAA 自动化明日方舟。当前已按“手机 ADB 模式”配置完成，并包含定时脚本。

从零部署教程（Linux + 手机）：
- 见 `SETUP_FROM_SCRATCH.md`

# 0. 目录结构（重要文件）

- docker-compose.yml
- maa/Dockerfile
- maa-config/profiles/default.toml
- maa-config/tasks/infrast.json
- maa-config/infrast/243_4times_tbt20251104_noskip.json
- run_maa_infrast.sh
- maa-cron.log

# 1. 前置条件（第一次必做）

1. 安装工具
   - adb
   - docker 与 docker compose
   - scrcpy（用于可视化手机屏幕）

2. 确认命令可用
   - adb devices
   - docker compose version
   - scrcpy --version

3. 手机开启开发者选项与 USB 调试
   - 连接数据线后，手机弹窗选择“允许 USB 调试”

# 2. 手机 ADB 模式（推荐）

以下步骤为“真实手机”模式的完整流程，按顺序执行。

1. 确认手机已连接并授权
   - adb devices
   - 期望看到：RF8N316396H    device

2. 设置 MAA 连接到手机
   - 编辑 maa-config/profiles/default.toml
   - 设置为：
     [connection]
     preset = "ADB"
     address = "RF8N316396H"
     config = "General"
     adb_path = "adb"

3. 构建 MAA 镜像（首次一次即可）
   - docker compose build maa

4. 初始化与更新 MAA 资源（首次一次即可）
   - docker compose run --rm maa maa install
   - docker compose run --rm maa maa update

5. 测试任务配置是否可被识别
   - docker compose run --rm maa maa run --dry-run infrast
   - 看到 Summary 里有 [Infrast] 即可

6. 正式运行基建（批处理模式）
   - docker compose run --rm maa maa run infrast -a RF8N316396H --batch

# 3. 可视化打开手机（观察 MAA 操作）

MAA 本身是命令行工具，没有图形界面。要看到手机上的操作，请用 scrcpy。

1. 打开手机屏幕镜像
   - scrcpy -s RF8N316396H

2. 运行 MAA 时，scrcpy 窗口会显示自动操作过程

如果 scrcpy 无法打开：
- 先确认 adb devices 可见
- 重新插拔数据线并允许 USB 调试

# 4. 打开/关闭明日方舟（手机）

1. 打开明日方舟
   - adb -s RF8N316396H shell monkey -p com.hypergryph.arknights -c android.intent.category.LAUNCHER 1

2. 强制关闭明日方舟
   - adb -s RF8N316396H shell am force-stop com.hypergryph.arknights

3. 如果包名不一致，先查包名
   - adb -s RF8N316396H shell pm list packages | grep -i arknights

# 5. 基建策略与配置

1. 基建策略文件位置
   - maa-config/infrast/243_4times_tbt20251104_noskip.json

2. 基建任务配置文件
   - maa-config/tasks/infrast.json
   - 当前内容：
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

3. 运行基建
   - docker compose run --rm maa maa run infrast -a RF8N316396H --batch

# 6. 战斗刷理智（maa fight）

战斗刷理智建议直接用 `maa fight` 命令，不需要写任务文件。

1. 查看参数说明（了解有哪些可改选项）
   - docker compose run --rm maa maa fight --help

2. 刷指定关卡（示例：1-7，刷 30 次，开 6 倍代理）
   - docker compose run --rm maa maa fight 1-7 -a RF8N316396H --times 30 --series 6 --batch

3. 不写关卡名（将刷当前/上次关卡）
   - docker compose run --rm maa maa fight -a RF8N316396H --times 30 --series 6 --batch

4. 使用理智药 / 源石（示例）
   - docker compose run --rm maa maa fight 1-7 -a RF8N316396H --medicine 5 --expiring-medicine 2 --stone 0 --times 30 --batch

5. 按掉落数量停止（示例：碎石 100 个就停）
   - 先查物品 ID：/home/tian/ark/maa-data/resource/item_index.json
   - 示例（碎石 ID 假设为 30012）：
     docker compose run --rm maa maa fight 1-7 -a RF8N316396H -D30012=100 --batch

6. 如果需要自动上报掉落（可选）
   - 企鹅物流：加 --report-to-penguin（可选 --penguin-id）
   - 一图流：加 --report-to-yituliu（可选 --yituliu-id）

# 7. 批处理模式（MAA --batch）

批处理模式用于避免交互式提示，适合定时任务。

1. 单次批处理运行
   - docker compose run --rm maa maa run infrast -a RF8N316396H --batch

2. 多任务批处理（示例顺序执行）
   - docker compose run --rm maa maa run infrast -a RF8N316396H --batch
   - docker compose run --rm maa maa run mall -a RF8N316396H --batch

# 8. 批处理更改配置（快速批量修改）

以下是“常见快速改法”，适合脚本或批处理。

1. 更换基建策略文件名
   - sed -i 's/243_4times_tbt20251104_noskip.json/NEW_FILE.json/' maa-config/tasks/infrast.json

2. 切换无人机用途
   - sed -i 's/"drones": "Money"/"drones": "Trade"/' maa-config/tasks/infrast.json

3. 更换设备序列号
   - sed -i 's/address = ".*"/address = "NEW_SERIAL"/' maa-config/profiles/default.toml

4. 修改后验证 JSON 语法
   - python3 -m json.tool maa-config/tasks/infrast.json > /dev/null

5. 快速切换刷图关卡（命令行方式）
   - 直接改命令里的关卡名即可：
     docker compose run --rm maa maa fight 1-7 -a RF8N316396H --times 30 --series 6 --batch
     docker compose run --rm maa maa fight 12-7 -a RF8N316396H --times 30 --series 6 --batch

# 9. 定时运行（已配置）

1. 定时脚本
   - /home/tian/ark/run_maa_infrast.sh
   - 日志：/home/tian/ark/maa-cron.log

2. 当前 cron（每天四次）
   - 30 1 * * * /home/tian/ark/run_maa_infrast.sh
   - 30 5 * * * /home/tian/ark/run_maa_infrast.sh
   - 30 13 * * * /home/tian/ark/run_maa_infrast.sh
   - 30 21 * * * /home/tian/ark/run_maa_infrast.sh

3. 查看是否生效
   - crontab -l
   - tail -n 200 /home/tian/ark/maa-cron.log

# 10. redroid 模式（可选）

如果你要用 redroid 而不是手机：

1. 启动容器
   - docker compose up -d redroid

2. 连接 ADB
   - docker exec arknights-redroid start adbd
   - adb connect 127.0.0.1:5555

3. scrcpy 可视化
   - /usr/bin/scrcpy -s 127.0.0.1:5555

# 11. 常见问题排查

1. adb 设备显示 offline
   - adb disconnect
   - 重新插拔数据线并允许 USB 调试

2. MAA 找不到自定义基建文件
   - 确认文件在 maa-config/infrast/
   - 确认 tasks/infrast.json 的 filename 完全一致

3. MAA 无法连接设备
   - adb devices 确认序列号
   - default.toml 的 address 是否一致

4. 定时没生效
   - crontab -l 是否有配置
   - 查看 maa-cron.log

# 12. 基建换班策略文件（243_4times_*.json）说明

当前基建任务使用的自定义文件是：
- maa-config/infrast/243_4times_tbt20251104_noskip.json

对应绑定配置在：
- maa-config/tasks/infrast.json

关键字段：
- "custom": true
- "filename": "243_4times_tbt20251104_noskip.json"

这意味着：
- 你改动该 JSON 文件后，不需要重启容器，也不需要重建镜像
- 下一次运行 `maa run infrast` 就会直接使用你修改后的方案

注意事项：
1. 文件名不变时，直接生效
2. 如果你改了文件名，必须同步修改 tasks/infrast.json 的 filename
3. JSON 语法错误会导致任务失败
4. 修改后建议用以下命令检查语法：
   - python3 -m json.tool /home/tian/ark/maa-config/infrast/243_4times_tbt20251104_noskip.json > /dev/null

# 13. 当前任务顺序（脚本内）

脚本：/home/tian/ark/run_maa_infrast.sh
执行顺序：
1. 唤醒屏幕 + 解锁滑动 + 设置分辨率
2. 启动游戏
3. maa startup
4. maa run infrast（基建换班，包含线索相关处理）
5. maa run award（日常领取）
6. maa run recruit（公招）
7. maa run mall（信用商店，包含访问好友）
8. maa fight TA-9（使用 48h 内过期理智药）

如果你希望调整顺序或只执行部分任务：
- 编辑 run_maa_infrast.sh，删除或移动相应的 maa run 段落即可

# 14. 新增任务文件清单

你现在已有这些任务文件：
- maa-config/tasks/infrast.json
- maa-config/tasks/award.json
- maa-config/tasks/recruit.json
- maa-config/tasks/mall.json

这些文件都可以单独执行：
- docker compose run --rm maa maa run award -a RF8N316396H --batch
- docker compose run --rm maa maa run recruit -a RF8N316396H --batch
- docker compose run --rm maa maa run mall -a RF8N316396H --batch
- docker compose run --rm maa maa run infrast -a RF8N316396H --batch


# 15. 全量配置汇总（可直接复制检查）

## 15.1 crontab（当前系统实际内容）

SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOME=/home/tian

30 1 * * * /home/tian/ark/run_maa_infrast.sh
30 5 * * * /home/tian/ark/run_maa_infrast.sh
30 13 * * * /home/tian/ark/run_maa_infrast.sh
30 21 * * * /home/tian/ark/run_maa_infrast.sh

## 15.2 MAA 连接配置

文件：/home/tian/ark/maa-config/profiles/default.toml

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

## 15.3 基建任务绑定

文件：/home/tian/ark/maa-config/tasks/infrast.json

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

## 15.4 奖励任务

文件：/home/tian/ark/maa-config/tasks/award.json

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

## 15.5 公招任务

文件：/home/tian/ark/maa-config/tasks/recruit.json

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

## 15.6 访问好友 / 收取线索

说明：当前使用的 MaaCore 不支持 `type: "Visit"` 任务类型。  
改为以下组合实现：
- `mall.json` 里的 `visit_friends: true` 负责访问好友
- `infrast.json` 负责基建中的线索相关操作

## 15.7 信用商店

文件：/home/tian/ark/maa-config/tasks/mall.json

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

## 15.8 基建策略文件

文件：/home/tian/ark/maa-config/infrast/243_4times_tbt20251104_noskip.json

说明：
- 修改该文件后，下一次 `maa run infrast` 会直接使用修改后的内容
- 文件名改动时，需要同步改 tasks/infrast.json 的 filename

## 15.9 执行脚本

文件：/home/tian/ark/run_maa_infrast.sh

说明：
- 脚本内执行顺序：startup → infrast → award → recruit → mall → fight(TA-9)
- 包含唤醒屏幕、设置分辨率、解锁滑动
- 包含并发锁：同一时间只允许一个脚本实例运行
- 日志输出到 /home/tian/ark/maa-cron.log
