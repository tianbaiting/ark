# 关卡选择说明

## 当前默认行为

`run_maa_infrast.sh` 默认使用自动关卡选择：

```bash
FIGHT_STAGE="${FIGHT_STAGE:-auto}"
```

当 `FIGHT_STAGE=auto` 时，脚本会在刷图前运行：

```bash
docker compose run --rm maa maa activity --batch Official
```

然后把输出交给 `scripts/maa_select_activity_stage.sh`。选择器会选第一条包含以下关键词的活动关卡：

- `搓玉`
- `合成玉`
- `orundum`

如果没有找到搓玉关，或者 `maa activity` 查询失败，脚本会回退到：

```text
AP-5 -> 1-7
```

实际选择结果会写进：

```bash
/home/tian/ark/maa-cron.log
```

## 我想临时自己选择关卡

临时跑一次时，用环境变量覆盖即可，不需要改文件：

```bash
cd /home/tian/ark
FIGHT_STAGE=MT-9 ./run_maa_infrast.sh
```

其他例子：

```bash
FIGHT_STAGE=AP-5 ./run_maa_infrast.sh
FIGHT_STAGE=1-7 ./run_maa_infrast.sh
FIGHT_STAGE=CE-6 ./run_maa_infrast.sh
```

这样只影响这一次手动运行。下一次 cron 仍按 crontab 里的配置运行。

## 我想长期固定某个关卡

推荐改 crontab，而不是改脚本。先打开：

```bash
crontab -e
```

把日常任务行从：

```cron
30 1 * * * /home/tian/ark/run_maa_infrast.sh
```

改成：

```cron
30 1 * * * FIGHT_STAGE=MT-9 /home/tian/ark/run_maa_infrast.sh
```

如果四个时间点都要固定关卡，就四行都加同样的 `FIGHT_STAGE=...` 前缀。

恢复自动选择时，删掉 `FIGHT_STAGE=MT-9`，或者改成：

```cron
30 1 * * * FIGHT_STAGE=auto /home/tian/ark/run_maa_infrast.sh
```

## 我想切换服务器活动数据

自动选择默认看 `Official` 活动数据：

```bash
FIGHT_ACTIVITY_CLIENT="${FIGHT_ACTIVITY_CLIENT:-Official}"
```

如果要看日服：

```bash
FIGHT_ACTIVITY_CLIENT=YoStarJP ./run_maa_infrast.sh
```

可用值通常包括：

```text
Official
Bilibili
Txwy
YoStarEN
YoStarJP
YoStarKR
```

## 我想先看看当前会选什么

直接运行：

```bash
cd /home/tian/ark
docker compose run --rm maa maa activity --batch Official
docker compose run --rm maa maa activity --batch Official | scripts/maa_select_activity_stage.sh
```

第一条命令显示 MAA 当前识别到的活动关卡，第二条命令只输出自动选择器最终选中的关卡。

## 我想验证某个关卡名是否能被 MAA 解析

先 dry-run：

```bash
cd /home/tian/ark
docker compose run --rm maa maa fight MT-9 --dry-run -a RF8N316396H --batch
```

如果 dry-run 没有配置错误，再手动跑：

```bash
docker compose run --rm maa maa fight MT-9 -a RF8N316396H --expiring-medicine 99 --series 0 --batch
```

设备序列号以 `maa-config/profiles/default.toml` 里的 `address` 为准。

## 我想刷当前或上次关卡

MAA 支持不传关卡名，表示刷当前或上次关卡：

```bash
cd /home/tian/ark
docker compose run --rm maa maa fight -a RF8N316396H --expiring-medicine 99 --series 0 --batch
```

这个模式没有接进 `run_maa_infrast.sh` 的日常流程。日常流程目前总是先解析出一个关卡名，再执行刷图和回退链。

## 资源更新和关卡选择的关系

活动数据由独立 cron 更新，不再绑在日常跑图脚本里：

```cron
10 */6 * * * /home/tian/ark/run_maa_update.sh
```

手动刷新活动和关卡资源：

```bash
cd /home/tian/ark
./run_maa_update.sh
```

更新日志在：

```bash
/home/tian/ark/maa-update.log
```

如果活动刚开但自动选择还没看到新关卡，先手动跑一次 `./run_maa_update.sh`，再用 `maa activity` 检查。
