# 明日方舟 + MAA（Docker / ADB / redroid）

本仓库用于通过 Docker 化的 MaaAssistantArknights 自动化明日方舟。
当前默认运行方式是 Android 手机 ADB 直连；`redroid` 仍保留为可选方案。

详细操作内容已经拆成 agent 和 repo-local skill，README 只保留入口和高频命令，避免多处文档漂移。

## 文档入口

- `AGENTS.md`
  - 仓库级常驻指令，适合让代理快速理解这里的运行方式和修改边界
- `.codex/skills/ark-maa-ops/SKILL.md`
  - repo-local skill 入口，细分到命令、配置、自动化、排障四类参考资料
- `SETUP_FROM_SCRATCH.md`
  - 从零部署 Linux + 手机 + MAA 的完整流程
- `memo_arknights.md`
  - 个人背景记录和历史方案笔记

skill 参考资料：
- `.codex/skills/ark-maa-ops/references/commands.md`
- `.codex/skills/ark-maa-ops/references/configuration.md`
- `.codex/skills/ark-maa-ops/references/automation.md`
- `.codex/skills/ark-maa-ops/references/troubleshooting.md`

## 快速开始

1. 确认手机可见

```bash
adb devices
```

2. 查看当前版本

```bash
cd /home/tian/ark
docker compose run --rm maa maa version
```

3. 更新 `maa-cli` + MaaCore + 资源

```bash
docker compose build --no-cache maa
docker compose run --rm maa maa update
docker compose run --rm maa maa version
```

4. 校验基建任务能否识别

```bash
docker compose run --rm maa maa run infrast --dry-run -a RF8N316396H --batch
```

5. 正式运行常用任务

```bash
docker compose run --rm maa maa run infrast -a RF8N316396H --batch
docker compose run --rm maa maa run award -a RF8N316396H --batch
docker compose run --rm maa maa run recruit -a RF8N316396H --batch
docker compose run --rm maa maa run mall -a RF8N316396H --batch
docker compose run --rm maa maa fight 1-7 -a RF8N316396H --times 30 --series 6 --batch
```

将 `RF8N316396H` 替换为 `maa-config/profiles/default.toml` 中的 `address` 即可。

## 关键文件

- `docker-compose.yml`
- `maa/Dockerfile`
- `maa-config/profiles/default.toml`
- `maa-config/tasks/infrast.json`
- `maa-config/tasks/award.json`
- `maa-config/tasks/recruit.json`
- `maa-config/tasks/mall.json`
- `maa-config/infrast/243_4times_tbt20251104_noskip.json`
- `run_maa_infrast.sh`
- `maa-cron.log`

## 更新原则

- 不要使用 `maa self update`
- 这个仓库的 `maa` 容器是一次性的，自更新结果会随容器销毁丢失
- `maa-cli` 升级方式是重建 `maa` 镜像
- MaaCore 和资源通过 `docker compose run --rm maa maa update` 刷新
- 仅刷新资源时可用 `docker compose run --rm maa maa hot-update`

## 自动化入口

- 定时脚本：`/home/tian/ark/run_maa_infrast.sh`
- 日志文件：`/home/tian/ark/maa-cron.log`

查看最近日志：

```bash
tail -n 200 /home/tian/ark/maa-cron.log
```
