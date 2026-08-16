# QFT 矿物处理 & AE 产物维持 控制系统

基于 OpenComputers 的双优先级自动化控制系统。

## 功能概述

| 功能 | 优先级 | 描述 |
|------|--------|------|
| **产物维持** | 高 | 读取 ME 请求器(Level Maintainer)的目标和阈值，监控网络库存，低于阈值自动发起 AE 合成订单 |
| **矿物处理** | 低 | 按配置列表循环，通过 WR-CBE 无线红石控制 QFT 输入总线开关切换配方，空闲超时自动跳到下一个 |

## 文件结构

```
qft_control/
├── config.lua       # 所有可配置参数（矿物列表、超时、扫描间隔等）
├── components.lua   # 组件扫描与安全初始化
├── crafting.lua     # AE 合成下单（CPU管理、请求、追踪、失败重试）
├── inventory.lua    # 网络库存查询（物品/流体）
├── maintainer.lua   # Level Maintainer 读取（目标产物+阈值解析）
├── mineral.lua      # 矿物处理核心（循环切换 + QFT 超时检测）
├── redstone.lua     # WR-CBE 无线红石控制
├── ui.lua           # 屏幕仪表板
└── main.lua         # 主入口（双优先级调度）
```

## 硬件要求

| 组件 | 用途 | 必需？ |
|------|------|--------|
| T3 机箱 + APU + 内存 + 硬盘 | OC 电脑本体 | ✅ |
| ME 接口 (me_interface) | 查询 AE 网络库存、发起合成 | ✅ |
| T2 红石卡 (redstone) | WR-CBE 无线红石控制 | ✅ |
| QFT 量子操纵者 (gt_machine) | 矿物处理目标机器 | ✅ |
| Level Maintainer xN | 产物维持的目标和阈值配置 | 可选 |
| 适配器 + MFU | 连接 QFT 和请求器到 OC | ✅ |
| GPU + 屏幕 | 状态仪表板显示 | 推荐 |

## 快速开始

1. 将 `qft_control/` 文件夹复制到 OC 的 `/home` 目录
2. 用适配器和 MFU 连接以下设备到 OC：
   - 主网的 ME 接口（或二合一接口）
   - QFT 量子操纵者主机
   - 所有需要读取的 Level Maintainer（请求器）
3. 编辑 `config.lua` 配置矿物处理列表和参数
4. 在 OC 终端运行：
   ```
   cd /home/qft_control
   main
   ```

## 配置说明

编辑 `config.lua`：

```lua
-- 矿物处理列表
MINERAL_LIST = {
    { name = "pt_metals", displayName = "铂系金属", wirelessFreq = 1, timeout = 120, cycleTime = 30 },
    -- frequency: WR-CBE 无线红石频率（与远处的 ME 输出总线接收端一致）
    -- timeout: QFT 空闲超时（秒），超时后自动切换到下一项
    -- cycleTime: 最短运行时间（秒），此时间内不检测超时
}

-- QFT 配置
QFT_CONFIG = {
    machineName = "multimachine.quantumforcetransformer",
    checkInterval = 5,    -- 状态检查间隔（秒）
    minRunTime = 10,      -- 机器启动保护时间（秒）
}

-- 产物维持配置
MAINTENANCE_CONFIG = {
    rescanInterval = 60,         -- 请求器重新扫描间隔（秒）
    inventoryCheckInterval = 10, -- 库存检查间隔（秒）
    maxRetryHalf = 10,           -- AE 合成失败减半重试次数
    lowestOrderQuantity = 1000,  -- 最低合成请求数量
}
```

## 工作原理

```
主循环 (每秒):
  │
  ├── 产物维持检查 (高优先级)
  │   ├── 定期扫描 Level Maintainer → 获取目标列表
  │   ├── 检查 AE 网络库存 → 判断是否低于阈值
  │   └── 低于阈值 → 发起 AE 合成订单
  │
  ├── 矿物处理循环 (低优先级，仅无维持任务时)
  │   ├── QFT 运行中？ → 不操作
  │   ├── QFT 空闲 < timeout？ → 等待
  │   └── QFT 空闲 >= timeout？ → 切换 WR-CBE 频率 → 下一项
  │
  └── 更新屏幕仪表板
```

## WR-CBE 红石控制逻辑

- 每个矿物项目对应一个无线红石频率
- 远处的 ME 输出总线设置为"有红石信号时工作"
- OC 切换到频率 X 并开启输出 → 对应输出总线开始向 QFT 输入仓输送配方原料
- QFT 完成当前配方后自然停止 → 空闲超时 → OC 切换频率 → 开始下一项

## 产物维持流程

1. 在 Level Maintainer 中像普通请求器一样配置目标产物和阈值
2. OC 定期读取所有请求器的配置
3. 通过 ME 接口查询网络中该产物的存量
4. 存量低于阈值时，通过 AE 合成 API 发起自动订单
5. 支持多 CPU 并行合成（需每个 CPU 配备合成监控器）
