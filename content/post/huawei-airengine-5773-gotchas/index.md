---
title: (Chinese Only) 华为 AirEngine 5773-21 踩坑记录
description: 买了台华为 AirEngine 5773-21 回来发现只有 FIT 模式，没有 FAT 模式 、Leader AP 功能，需要升级固件到 V600R024C10 及以上版本。本文作为踩坑记录。
slug: huawei-airengine-5773-gotchas
date: 2025-12-13 16:00:00+0800
categories:
    - Networking
    - Wireless
tags:
    - Networking
    - Wireless
---

## 背景

最近老家重建，家里需要重新布置无线网络。考虑到自建别墅面积比较大，单纯使用单个无线路由器覆盖不够，因此多个 AP 肯定是需要的。家里在装修的时候就每个房间吊顶中有留超六类线缆，这种情况对 AP 来说是非常友好的，因此决定使用企业级无线接入点（AP）来组建无线网络。由于华为系列的 AP 在国内使用量较大，闲鱼上非常好捡公司下架下来的二手设备，因此考虑华为系列的 AP。这些企业级 AP 并不需要担心二手问题，他们的质量是消费级产品无法比拟的，稳定性也是非常强。

目前是 2025 年 12 月，虽然在国内 Wi-Fi 7 （802.11be）的 6 GHz 频段还没批准无法使用（损失不少性能），但是上一下 Wi-Fi 7  追一下新也没什么问题。华为 Wi-Fi 7 AP 是 AirEngine xx7x 产品，我闲鱼花了 500 多，激情下单了一台 AirEngine 5773-21 （有一个 2.5 Gbe PoE 口）。先买一台测测，为之后全屋部署积累经验，如果好用，再给每个房间买一台（后续更新）。

![AirEngine 5773-21](images/ap.jpg)

回来一查，这设备保修到 2028 年 3 月，现在才 2025 年 12 月，还有快 3 年的保修期，很新啊。

![AirEngine 5773-21 保修](images/coverage.png)

我目前的打算是不购买单独的 AC 控制器（AC 用于统一管理其他 AP ），因为我没有几十上百个 AP 需要管理。对于只需管理十几台 AP 来说，AC 控制器的成本和复杂度都不划算。因此打算使用华为 AP 自带的 Leader AP 模式组网（按道理华为的 AirEngine 系列大部分都是支持的，但是对于我买的 AirEngine 5773-21 来说，这里是个大坑，后面会讲）。这种模式下，Leader AP 可以担任 AC 的角色，统一管理其他 FIT AP ，每个 Leader AP 具体能管理几台 FIT AP 可以上华为 Info-Finder 上查询（基本上都大于 16 台）。

（组网方案后续更新，包括多 AP 的组网方案， VLAN 配置 IOT 设备隔离等）


## 首次启动

插上网线（注意，如果使用 PoE 的话需要满足 802.3at ，否则可能降速，或者使用 DC 供电）

![AP 插电](images/ap-plugged-in.jpg)

注意，开机过程中状态灯常亮，等到状态灯快速闪烁说明开机完成等待配置。

现在华为的 AP 默认会用 DHCP 获取 IP 地址，因此只需根据 AP 的 MAC 地址（在 AP 背后会写）在 DHCP 服务器上找到对应的 IP 地址，就可以知道 AP 目前的 IP 地址了

![DHCP](images/dhcp.png)

然后浏览器打开该 IP 即可登录 Web 管理界面（并不）。

## 踩坑

然后浏览器打开该 IP 即可登录 Web 管理界面（吗？？？？），我发现并不能。

按道理华为 Wi-Fi 6 系列（比如 AirEngine 5761 ）都是可以直接登录 Web 管理页面的，Wi-Fi 7 更新不应该不行，而且官方 AirEngine 5773-21 的[彩页](https://e.huawei.com/cn/material/enterprise/5d5164cf207149b0b210988b1bb7996d)中也说可以用做 FAT AP / Leader AP ，怎么回事？

我后面用 SSH 登录设备（后面会说怎么登录），没有说当前是 FIT 还是 FAT 模式（老的 AP 会在 SSH 登录的时候就提示）。而且这个命令行看的我一脸懵，老的 Wi-Fi 6 AP 都是直接 `system-view` 就能配置，然后命令也是传统的那一套。这新的 AP 一上来就是个 `MDCLI>` 提示符（一看就是新搞的东西，里面的命令也完全变了，我根本没时间去学习这些新命令。（后面才知道，必须升级系统后，用 `switch cli` 从 MC-CLI 切换到传统 CLI 模式，才能用老的命令行方式配置，但是建议还是用新的 MD-CLI ，因为传统 CLI 里面基本没啥功能了）

看了一圈文档，说可以输入 `edit-config` 修改配置，然后发现提示没有权限。WTF？我管理员还能没权限？后面才知道，原来没有权限其实代表当前 AP 在 FIT 模式下（这报错给用户带来多少困扰），必须切换到 FAT 模式才有权限修改配置。那么问题来了，我都没权限做任何配置，我怎么切换到 FAT 模式（况且我也没找到切换 FAT 模式的命令）？

后面折腾一圈才发现（各种根据文档中的蛛丝马迹去猜），是我当前固件版本太老了（`V600R023C10`），华为并没有在早期固件中实现 FAT AP / Leader AP 功能（设备都发布了，功能还没做好是吧），必须升级到 `V600R024C10` 及以上版本才有该功能，写文章时最新版本 是 `V600R025C00` 。OK，问题找到，接下来就是升级固件了。

但是华为是出了名的不给资料，比如我想下载新版本固件，就算我注册了账号、也绑定了 AP 的序列号、也给了华为公司名称 + 设备序列号
也审核 **通过** 了 AirEngine 5773-21 的资料和软件下载权限，但是你还是下不到 AirEngine 5773-21 的固件，华为官网上根本 **没有** 提供任何一个版本固件的下载链接（截至 2025 年 12 月），你只能下到补丁（这还是从其他 AP 找的补丁，刚好能用到 AirEngine 5773-21 上）。

最后我只能在闲鱼花钱上找有权限的人代下的固件，版本号 `V600R024C10` ，也就是第一版支持 FAT AP / Leader AP 功能的固件。本来我想下载当前最新的 `V600R025C00` ，但是我没找到人能下载这个版本，遂放弃， `V600R024C10` 也不是不能用。

## 首次设备设置

> 可以按住设备旁的 Default 按钮数十秒来重置设备。观察指示灯，变成常亮表示成功。重置成功后会重启，开机过程中状态灯常亮，等到状态灯快速闪烁说明开机完成等待配置。

你需要 SSH 上去 `ssh admin@<AP_IP_ADDRESS>` ，默认密码是 `admin@huawei.com` 。首次登录会提示你修改密码，按照提示修改后会登出，下次使用新密码再登录即可。

查看当前版本

```
[admin@HUAWEI]
MDCLI> display system/system-info/software-name
"AirEngineX773_V600R023C10SPC200.cc"            # 当前版本
```

我目前的版本是 `V600R023C10SPC200` ，也就是 `V600R023C10` （后面的 `SPC200` 是补丁），需要升级到 `V600R024C10` 及以上版本才有 FAT AP / Leader AP 功能。


## 固件升级

首先需要找台机器开启 FTP 服务端，设置好用户名密码，打开读写权限（macOS App Store 中有个 QuickFTP 还是很好用的），到时候 AP 需要通过 FTP 上传和下载固件。

然后你需要有一个 `V600R024C10` 及以上版本的固件文件，放到 FTP 的根目录下面。

需要使用的固件名称通常长这样，两者都行：

- `AirEngineX773_V600R024C10.cc` （不带补丁的基础固件）
- `AirEngineX773_V600R024C10SPC100.cc` （带补丁的完整固件）

其中：

- `AirEngineX773`：设备型号，比如 AirEngine 5773
- `V600R024C10`：版本号，R 或者 C 之后的数字越大，版本越新。
- `SPC100`：补丁号，可选。注意，不要下成 `SPH` 的热补丁了，补丁通常长这样 `AirEngineX773_V600R024C10SPH150.pat`（有 `SPH` 字样，且结尾是 `.pat` ），需要完整的固件（`.cc` 结尾）。


### 备份当前固件

SSH 登录设备操作

```
[admin@HUAWEI]
MDCLI> ftpc-transfer-file

[(x)admin@HUAWEI]/ftpc-transfer-file
MDCLI> command-type put

[*(x)admin@HUAWEI]/ftpc-transfer-file
MDCLI> local-file-name AirEngineX773_V600R023C10SPC200.cc    # 文件名与当前 AP 版本一致，查询：display system/system-info/software-name

[*(x)admin@HUAWEI]/ftpc-transfer-file
MDCLI> remote-file-name AirEngineX773_V600R023C10SPC200.cc   # 与上面保持一致即可

[*(x)admin@HUAWEI]/ftpc-transfer-file
MDCLI> server-ipv4-address 192.168.213.54                    # FTP 服务器 IP 地址

[*(x)admin@HUAWEI]/ftpc-transfer-file
MDCLI> server-port 2121                                      # FTP 服务器端口

[*(x)admin@HUAWEI]/ftpc-transfer-file
MDCLI> user-name xxxx                                        # FTP 用户名

[*(x)admin@HUAWEI]/ftpc-transfer-file
MDCLI> password                                              # FTP 密码
Enter password:
Confirm password:

[*(x)admin@HUAWEI]/ftpc-transfer-file
MDCLI> emit                                                  # 提交上传任务
{
  "huawei-ftpc:transfer-id": 3                               # 可以用这个 ID 查看任务状态
}

[admin@HUAWEI]
MDCLI> display ftpc/transfer-tasks                           # 检查是否备份成功
{
  "transfer-task": [
    {
      "transfer-id": 3,
      "command-type": "put",
      "server-address": "192.168.213.54",
      "server-port": 2121,
      "local-file-name": "AirEngineX773_V600R023C10SPC200.cc",
      "remote-file-name": "AirEngineX773_V600R023C10SPC200.cc",
      "status": "succeeded",                                # 表示成功
      "percentage": 100
    }
  ]
}
```

你应该可以在 FTP 服务器上看到备份下来的固件文件了。

### 下载新固件

```
[(x)admin@HUAWEI]/download-upgrade-package
MDCLI> base-software-directory AirEngineX773_V600R024C10SPC100.cc # 新固件文件名，注意要和 FTP 服务器上一致

[*(x)admin@HUAWEI]/download-upgrade-package
MDCLI> server-ip 192.168.213.54                                   # FTP 服务器 IP 地址

[*(x)admin@HUAWEI]/download-upgrade-package
MDCLI> server-port 2121                                           # FTP 服务器端口

[*(x)admin@HUAWEI]/download-upgrade-package
MDCLI> transfer-protocol ftp                                      # 传输协议

[*(x)admin@HUAWEI]/download-upgrade-package
MDCLI> user-name xxxx                                             # FTP 用户名

[*(x)admin@HUAWEI]/download-upgrade-package
MDCLI> password                                                   # FTP 密码
Enter password:
Confirm password:

[*(x)admin@HUAWEI]/download-upgrade-package
MDCLI> emit                                                       # 提交下载任务

[*(x)admin@HUAWEI]/download-upgrade-package
MDCLI> display software/download-result/                          # 查看下载状态
{
  "file-name": "AirEngineX773_V600R024C10SPC100.cc",
  "status": "succeeded",                                          # 表示下载成功
  "percentage": 100
}

[admin@HUAWEI]
MDCLI> display file-operation/                                    # 查看文件列表，确认新固件在设备上
{
  "dir": [
...
    {
      "file-name": "AirEngineX773_V600R024C10SPC100.cc",          # 新固件文件
      "dir-name": "backup:/",
      "attribute": "-rw-",
      "modify-time": "2024-11-12T12:05:04Z",
      "size": 52394852
    }
...
  ]
}
```

### 设置新固件为启动固件

```
[admin@HUAWEI]
MDCLI> startup-by-mode name AirEngineX773_V600R024C10SPC100.cc  # 设置启动固件，注意文件名要和上面一致

[admin@HUAWEI]
MDCLI> display cfg/startup-infos
{
  "startup-info": [
    {
      "position": "0",
      "configed-system-software": "AirEngineX773_V600R023C10SPC200.cc",
      "current-system-software": "AirEngineX773_V600R023C10SPC200.cc",
      "next-system-software": "AirEngineX773_V600R024C10SPC100.cc",    # 确认新固件已设置为下次启动固件
      "current-cfg-file": "",
      "next-cfg-file": "",
      "current-patch-file": "NULL",
      "next-patch-file": "NULL"
    }
  ]
}
```

注意，要是你之前安装了 patch ，可能会导致新系统安装不上，例如

```
[admin@HUAWEI]
MDCLI> display cfg/startup-infos
{
  "startup-info": [
    {
      "position": "0",
      "configed-system-software": "AirEngineX773_V600R023C10SPC200.cc", # 是的，华为拼错单词了
      "current-system-software": "AirEngineX773_V600R023C10SPC200.cc",
      "next-system-software": "AirEngineX773_V600R023C10SPC200.cc",  # 发现还是老的版本
      "current-cfg-file": "",
      "next-cfg-file": "",
      "current-patch-file": "AirEngineX773_V600R023SPH151.pat",      # 已安装 patch
      "next-patch-file": "AirEngineX773_V600R023SPH151.pat"
    }
  ]
}
```

这时候你需要把 patch 给清掉：

```
[admin@HUAWEI]
MDCLI>  delete-patch delete-type all
......
```

然后再设置启动固件即可。

### 重启设备

```
[admin@HUAWEI]
MDCLI> reboot
Warning: This operation will reboot the device.
Are you sure you want to continue? [Y(yes)/N(no)]:y
```

等设备起来，浏览器访问设备 IP 地址，应该就可以看到 Web 管理界面了。

![FIT 模式 Web 管理界面](images/fit-webui.png)

选择右上角 FIT 按钮，改成 FAT 模式即可使用 Leader AP 功能，重启后即可变成 Leader AP ，可以管理其他 FIT AP 了。

![FAT 模式 Web 管理界面](images/fat-webui.png)


## 安装补丁（Patch）

补丁是在基础版本上修复 bug 或者增加小功能的。补丁一般靠自己注册完设备就能在官网下到，下载补丁的时候，注意产品型号不需要选择 AirEngine 5773-21 ，因为太新了，华为官网上甚至没有这个型号。直接选择全部，只要版本对的上即可，比如我当前基础版本是 `V600R024C10` ，那么补丁就需要选择 `V600R024C10SPH181` 这种补丁，表示在 `V600R024C10` 基础版本上打的热补丁 `SPH181` ，数字越大表示补丁越新。补丁文件名通常长这样 `AirEngineX773_V600R024C10SPH181.pat` ，注意是 `.pat` 结尾。

![下载补丁](images/download-patch.png)

下载后，放到 FTP 服务器根目录下，然后 SSH 登录设备，执行以下命令安装补丁：

```
[admin@HUAWEI]
MDCLI> ftpc-transfer-file

[(x)admin@HUAWEI]/ftpc-transfer-file
MDCLI> command-type get

[*(x)admin@HUAWEI]/ftpc-transfer-file
MDCLI> local-file-name AirEngineX773_V600R024C10SPH181.pat     # 补丁文件名，注意和 FTP 服务器上一致

[*(x)admin@HUAWEI]/ftpc-transfer-file
MDCLI> remote-file-name AirEngineX773_V600R024C10SPH181.pat    # 与上面保持一致即可

[*(x)admin@HUAWEI]/ftpc-transfer-file
MDCLI> server-ipv4-address 192.168.213.54                      # FTP 服务器 IP 地址

[*(x)admin@HUAWEI]/ftpc-transfer-file
MDCLI> server-port 2121                                        # FTP 服务器端口

[*(x)admin@HUAWEI]/ftpc-transfer-file
MDCLI> user-name xxx                                           # FTP 用户名

[*(x)admin@HUAWEI]/ftpc-transfer-file
MDCLI> password                                                # FTP 密码
Enter password:
Confirm password:

[*(x)admin@HUAWEI]/ftpc-transfer-file
MDCLI> emit                                                    # 提交下载任务
{
  "huawei-ftpc:transfer-id": 1
}

[admin@HUAWEI]
MDCLI> display ftpc/transfer-tasks/                            # 查看任务状态
{
  "transfer-task": [
    {
      "transfer-id": 1,
      "command-type": "get",
      "server-address": "192.168.213.54",
      "server-port": 2121,
      "local-file-name": "AirEngineX773_V600R024C10SPH181.pat",
      "remote-file-name": "AirEngineX773_V600R024C10SPH181.pat",
      "status": "succeeded",                                   # 表示成功
      "percentage": 100
    }
  ]
}

[admin@HUAWEI]
MDCLI> load-patch name AirEngineX773_V600R024C10SPH181.pat load-type run  # 安装补丁，注意文件名与需要安装的补丁一致

[admin@HUAWEI]
MDCLI> display patch/operation-schedules    # 查看安装进度
{
  "operation-schedule": [
    {
      "phase": "load-patch",
      "status": "successful",
      "schedule": 100             # 等待进度 100%
    },
    {
      "phase": "delete-patch",
      "status": "not-started",
      "schedule": 0
    },
    {
      "phase": "startup-next-patch",
      "status": "not-started",
      "schedule": 0
    },
    {
      "phase": "reset-startup-patch",
      "status": "not-started",
      "schedule": 0
    }
  ]
}

[admin@HUAWEI]
MDCLI> display patch/patch-infos
{
  "patch-info": [
    {
      "name": "AirEngineX773_V600R024C10SPH181.pat",    # 验证补丁安装成功
      "version": "V600R024C10SPH181",
      "state": "running",
      "runtime": "2025-12-13T21:39:48+08:00",
      "path": "/",
      "operations": {
        "operation": [
          {
            "position": "0",
            "position-type": "MPU",
            "upgrade-mode": "reset-board"        # 某些补丁需要重启设备才能生效
          }
        ]
      }
    }
  ]
}
```

你也可以在 Web 管理界面上查看补丁是否安装成功。

![补丁安装成功](images/patch-webui.png)

## Bonus: 启用 IPv6

我发现 AP 下面的设备获取不到 IPv6 地址（我内网中 IPv6 配置都是正确的），基本上肯定是在 AP 导致的 IPv6 地址无法下发。

后面了解华为 AP 默认不开 IPv6 报文转发。原因是：华为认为 IPv4 是主流，在 IPv4 网络中，如果存在较多 IPv6 协议报文，会影响无线网络性能，也会损耗设备的 CPU 处理能力。因此在纯 IPv4 网络中，可以通过不处理 IPv6 无线报文来提高 IPv4 网络性能。

不过，我就是要用 IPv6 ，因此要去把 WLAN 处理 IPv6 报文的功能打开（ Web UI 没有，要命令行开），SSH 登录设备，执行以下命令：

> 官方文档里面其实有这个，但是我找半天没找到，在：“参考-MD-CLI配置参考-WLAN配置-WLAN用户管理” 里面。不是，你把 IPv6 相关配置放在“用户管理”里面？这跟用户管理有啥关系？

```
[admin@HUAWEI]
MDCLI> edit-config

[(gl)admin@HUAWEI]
MDCLI> wlan-sta-access

[(gl)admin@HUAWEI]/wlan-sta-access
MDCLI> sta-ipv6-switch true

[*(gl)admin@HUAWEI]/wlan-sta-access
MDCLI> commit
```

之后你的设备应该就能正确收发 IPv6 报文了。

## 结语

这告诉我们， AirEngine 5773-21 这种 Wi-Fi 7 新设备，还是太新了，所有的坑都得自己踩。与 Wi-Fi 6 的设备比如 AirEngine 5761 相比网上大把教程还是差太远了。不过也算是积累了一些经验，后续再买多台 AP 的时候就不会再踩这些坑了。

这次单台 AP 就放北京用了，年底回老家再配置多 AP 组网方案。
