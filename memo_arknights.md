### arknights


https://jedsek.xyz/posts/other/linux-arknights/#zhi-bo-tui-liu

甜布丁:
https://github.com/ArkMowers/arknights-mower?tab=readme-ov-file

甜布丁:
https://linsoap.xlog.app/Linux-ye-yao-ming-ri-fang-zhou-yi-jian-shou-cai?locale=zh

https://www.cnblogs.com/frinda/p/18702822

### 

LinSoap
LinSoap




关注
Null

17
关注者
5
正在关注

赞助
github
x
bilibili
主页
归档
连接
Linux也要明日方舟一键收菜
2024年1月12日
1013
最近从 Windows 全面转向 Manjaro 系统了，不得不说是真的很好用，转向 Manjaro 后，一个重要问题是如何像以前一样多开 MAA 明日方舟收菜，毕竟粥批每天都要收两次菜，多个号手动收起来太麻烦了。

模拟器#
首先是 MAA 支持三种 Linux 模拟器，一个是 AVD，一个是 Waydroid, 一个是 redroid，我选择使用 AVD，毕竟有 google 支持相对好用些吧。Waydroid 容器化的概念很好，但好像对 N 卡不支持就算了。
AVD 集成在 android-stuidio 中，先在 AUR 库中下载 android-stuidio (不要使用 flatpak 库，容器化会导致后续命令行启动模拟器变得很麻烦)，配置代理下载完 Sdk 后，选择

virtualdevice

当然你也可以不选择使用 android-stuidio 直接使用 AVD, 但是 android-studio 提供图形化界面能省很多事。
新建设备，设置分辨率 16：9 并大于 720p 即可，框架选择 (R - 30 - x86 - Android 11.0)，按照自己的配置为每个模拟器分配合适的配置，记得开启硬件加速，至此就成功创建 MAA 支持的模拟器，通过 adb 安装明日方舟即可。

newdevice

selectimage

detailsetting

每次打开模拟器都要打开 android-studio 非常的麻烦，其实可以直接从命令行打开模拟器

~/Android/Sdk/emulator/emulator -list-avds //获取模拟器列表
~/Android/Sdk/emulator/emulator -avd 模拟器名称 //启动指定模拟器 
MAA 配置#
从 MAA 官网下载并解压后，官方提供了几种方式调用 MAA，一个是 maa-cli, 一个是 Python 接口，分别为解压包根目录下的 AppImage 文件和 Python 文件夹，我看了看 maa-cli 的配置，配置任务和多开都比较麻烦，所以我就选择使用 Python 接口启动 MAA，打开 Python 文件夹下的 sample.py 文件，修改这个文件即可完成任务配置。首先是配置 adb 地址和 adb 设备名称，然后根据需求依照文档添加任务和设置任务参数，直接 python sample.py 即可直接开始收菜了。
每次任务的时候，都需要改 py 文件就非常麻烦了，所以可以在执行 python 的时候接受参数，选择要执行哪些任务即可，修改这个 sample 文件，以下给出我的任务配置

import json
import pathlib
import time
import argparse

from asst.asst import Asst
from asst.utils import Message, Version, InstanceOptionType
from asst.updater import Updater
from asst.emulator import Bluestacks

@Asst.CallBackType
def my_callback(msg, details, arg):
    m = Message(msg)
    d = json.loads(details.decode('utf-8'))

    print(m, d, arg)

if __name__ == "__main__":
    # 创建 ArgumentParser 对象
    parser = argparse.ArgumentParser(description='Arknights Assistant Script')

    # 添加每个任务的启用选项
    parser.add_argument('--start-up', action='store_true', help='Enable StartUp task')
    parser.add_argument('--recruit', action='store_true', help='Enable Recruit task')
    parser.add_argument('--infrast', action='store_true', help='Enable Infrast task')
    parser.add_argument('--visit', action='store_true', help='Enable Visit task')
    parser.add_argument('--mall', action='store_true', help='Enable Mall task')
    parser.add_argument('--fight', action='store_true', help='Enable Fight task')
    parser.add_argument('--award', action='store_true', help='Enable Award task')
    parser.add_argument('--stage', type=str, default=None, help='Specify the stage for Fight task')

    args = parser.parse_args()

    # 请设置为存放 dll 文件及资源的路径
    path = pathlib.Path(__file__).resolve().parent.parent

    # 设置更新器的路径和目标版本并更新
    # Updater(path, Version.Stable).update()

    Asst.load(path=path)

    asst = Asst()

    asst.set_instance_option(InstanceOptionType.touch_type, 'maatouch')

    # 请自行配置 adb 环境变量，或修改为 adb 可执行程序的路径
    if asst.connect('/home/linsoap/Android/Sdk/platform-tools/adb', 'emulator-5554'):
        print('连接成功')
    else:
        print('连接失败')
        exit()

    # 任务及参数请参考 docs/集成文档.md

    if args.start_up:
        asst.append_task('StartUp', {
            'client_type': 'Official',
            'start_game_enabled': True
        })

    if args.recruit:
        asst.append_task('Recruit', {
            'enable': True,
            'select': [4],
            'confirm': [3, 4],
            'times': 4
        })

    if args.infrast:
        asst.append_task('Infrast', {
            'enable': True,
            'facility': [
                "Mfg", "Trade", "Control", "Power", "Reception", "Office", "Dorm"
            ],
            'drones': "Money"
        })

    if args.visit:
        asst.append_task('Visit')

    if args.mall:
        asst.append_task('Mall', {
            'shopping': True,
            'buy_first': ['招聘许可', '龙门币'],
            'blacklist': ['家具', '碳'],
        })

    if args.fight:
        fight_params = {'enable': True}

        if args.stage:
            fight_params['stage'] = args.stage

        asst.append_task('Fight', fight_params)

    if args.award:
        asst.append_task('Award', {
            'enable': True,
        })

    asst.start()

    while asst.running():
        time.sleep(0)

Updater 类目前有一些问题，建议直接注释掉就好了，等什么时候修复了 bug 再取消注释就好
安装以上配置就可以使用以下命令启动 MAA 了。

python emulator-54.py --start-up --recruit --infrast --visit --mall --fight --stage AP-5 --award
一键脚本#
一键启动模拟器#
为了做到一键割草，还需要一个脚本一键启动多个模拟器，一键启动 MAA。
首先是复制多分 sample.py, 修改其中的 adb 名称即可。
遇到的第一个问题就是 AVD 的 adb 名称不是固定的，而是按照启动顺序分配的，我有两个官服账户和一个 b 服账号，随机的 adb 名字会导致 StarUp 任务失败，所以在多开的时候，需要指定端口，使得对于的客户端能够执行对应的任务。

#!/bin/bash

while [ "$#" -gt 0 ]; do
  case "$1" in
    --start)
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --all)
            echo "Starting all emulators..."
            /home/linsoap/Android/Sdk/emulator/emulator -avd aknz -ports 5554,5555 &
            /home/linsoap/Android/Sdk/emulator/emulator -avd aknz_1 -ports 5556,5557 &
            /home/linsoap/Android/Sdk/emulator/emulator -avd mrfz -ports 5558,5559 &
            shift
            ;;
          --list)
            echo "Available emulators:"
            /home/linsoap/Android/Sdk/emulator/emulator -list-avds
            shift
            ;;
          -*)
            echo "Unknown option: $1"
            exit 1
            ;;
          *)
            echo "Starting emulator: $1"
            /home/linsoap/Android/Sdk/emulator/emulator -avd "$1" &
            shift
            ;;
        esac
      done
      ;;
    --stop)
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --all)
            echo "Stopping all emulators..."
            /home/linsoap/Android/Sdk/platform-tools/adb -s emulator-5554 emu kill
            /home/linsoap/Android/Sdk/platform-tools/adb -s emulator-5556 emu kill
            /home/linsoap/Android/Sdk/platform-tools/adb -s emulator-5558 emu kill
            shift
            ;;
          -*)
            echo "Unknown option: $1"
            exit 1
            ;;
          *)
            echo "Stopping emulator: $1"
            /home/linsoap/Android/Sdk/platform-tools/adb -s "$1" emu kill
            shift
            ;;
        esac
      done
      ;;
    -*)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

以上是我用 ChatGPT 生成的一键启动脚本，按照自己对于的需求让 GPT 生成脚本就行了。

启动所有模拟器：./your_script.sh --start --all
启动特定模拟器：./your_script.sh --start <emulator_name>
查看可用模拟器列表：./your_script.sh --start --list
停止所有模拟器：./your_script.sh --stop --all
停止特定模拟器：./your_script.sh --stop <emulator_name>
一键启动 MAA#
修改 sample.py 后，使得其能够接受参数选择启用的任务，编写一键启动 MAA 脚本也变得容易，借助 ChatGPT 按照需求生成脚本就行了，以下是我的脚本。

#!/bin/bash

# 设置要执行的 Python 脚本文件列表
python_scripts=("emulator-54.py" "emulator-56.py" "emulator-58.py")

# 默认参数值
all_flag=false
only_fight_flag=false
unfight_flag=false
stage_value=""

# 解析命令行参数
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)
      all_flag=true
      ;;
    --only-fight)
      only_fight_flag=true
      ;;
    --unfight)
      unfight_flag=true
      ;;
    -stage|--stage)
      shift
      stage_value="$1"
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

# 检查参数组合
if [ "$all_flag" = true ] && [ "$only_fight_flag" = true ]; then
  echo "Cannot use --all and --only-fight together."
  exit 1
fi

# 构造命令行参数字符串
args="--start-up"

if [ "$all_flag" = true ] || [ "$only_fight_flag" = true ]; then
  args+=" --recruit --infrast --visit --mall --award --fight"
fi
if [ "$only_fight_flag" = true ]; then
  args+=" --fight"
fi

if [ -n "$stage_value" ]; then
  args+=" --stage $stage_value"
fi

# 串行执行三个 Python 命令
for script in "${python_scripts[@]}"; do
  # 输出当前执行的任务
  echo "Executing tasks in $script"

  # 串行执行
  python "$script" $args & echo "Finished tasks in $script" || echo "Failed to execute tasks in $script"
done

echo "All tasks completed"

这个脚本支持以下命令

--all: 启动所有任务，包括 --start-up, --recruit, --infrast, --visit, --mall, --award 和 --fight。
--only-fight: 启动所有任务，包括 --start-up 和 --fight。
--unfight: 启动所有任务，但不包括 --fight。
--stage <value> 或 -stage <value>: 指定任务关卡的值。
玩明日方舟玩的#
id

1. 模拟器
2. MAA配置
3. 一键脚本
3.1. 一键启动模拟器
3.2. 一键启动MAA
4. 玩明日方舟玩的

3

-

-


3
r0k1s#i
邱 璇洛 (ゝ∀･)
niracler

-

加载中...
此文章数据所有权由区块链加密技术和智能合约保障仅归创作者所有。
区块链标识
#60494-1
所有者
0x80b5d41640630f6c6fdc6dd959c12d2a73bae768
交易哈希
创作 0xd0f5f25c...5cc23c1059最后更新 0x53113096...2182581f95
IPFS 地址
ipfs://QmWqvz659sxfKK3wEMEhKtJBspwfoavibXamzhBgLQko5z
© LinSoap · 由 
 提供支持
github
x
bilibili




