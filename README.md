# ChronoVolume

一个用于把视频作为三维时间体进行审查、切片、体渲染、合成和导出的 macOS 应用。

ChronoVolume 会沿时间轴堆叠视频帧，并提供：

- `T / X / Y` 轴切片与任意参考面切片。
- 基于 Metal 的时间体渲染和模型表面显示。
- 图层、关键帧、表达式、混合模式与合成工作流。
- 图片、视频、高精度切片和实验性分布式导出。
- [AlphaCheater](https://github.com/Drangeeeeeee/AlphaCheater) 输出的 `A_color + B_alpha` 双视频导入。

常规视频优先由 AVFoundation 解码；MKV、FFV1 或高位深外部 Alpha 等组合可回退到 FFmpeg。

## 环境要求

- macOS 14 或更高版本
- Xcode 16 或更高版本（从源码构建）
- 支持 Metal 的 Apple Silicon 或 Intel Mac
- 处理 MKV、FFV1 或高位深 `B_alpha` 时需要 [FFmpeg](https://ffmpeg.org/) 和 `ffprobe`

macOS 可通过 Homebrew 安装 FFmpeg：

```bash
brew install ffmpeg
```

## 构建与运行

克隆仓库并打开工程：

```bash
git clone https://github.com/Drangeeeeeee/ChronoVolume.git
cd ChronoVolume
open ChronoVolume.xcodeproj
```

在 Xcode 中选择 `ChronoVolume` scheme 和本机 macOS destination，然后构建运行。

也可以使用命令行构建：

```bash
xcodebuild -project ChronoVolume.xcodeproj \
  -scheme ChronoVolume \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

## AlphaCheater 输入含义

ChronoVolume 可以通过界面中的 **导入AlphaCheater** 同时或分批导入两路视频：

- `A_color`：保存 RGB 颜色。其内嵌 Alpha 在外部 Alpha 模式下不参与结果；即使最终 Alpha 为 0，隐藏 RGB 也会保留。
- `B_alpha`：保存线性透明覆盖率。黑色为 `Alpha = 0`，白色为 `Alpha = 1`，灰色为中间透明度。

合并结果为：

```text
RGBA.rgb = A_color.rgb
RGBA.a   = normalize(B_alpha)
```

外部 `B_alpha` 会在帧解码和时间体构建阶段写入体素 Alpha，不是渲染阶段的 Track Matte。Straight Alpha 输入不会预乘 RGB；选择 Premultiplied 输入时，只会在与 `B_alpha` 对齐后尝试反预乘。

支持自动识别以下常见命名：

```text
name_A_color.mov + name_B_alpha.mkv
name-A_color.mov + name-B_alpha.mkv
A_color.* + B_alpha.*
```

同目录、同文件名前缀的素材会自动组成一个媒体项。之后单独导入缺失的另一半会原位补全；也可以在媒体栏中手动添加或移除 `A_color / B_alpha`。只导入 `B_alpha` 时会生成保留隐藏白色 RGB 的 Straight-Alpha 白模。

## 同步与数值解释

- 默认严格按两路视频的真实 presentation timestamp 对齐，不按帧数组下标配对。
- 显示方向会先规范化，再检查分辨率、帧率、时长、帧数与时间线。
- `nearestFrame`、重采样、缩放和截短策略必须由用户显式启用，不会静默放宽严格模式。
- `B_alpha` 支持灰度 8/10/12/16-bit、RGB(A) 指定通道、反转以及 full/limited range。
- YUV luma 优先直接读取亮度平面，外部 Alpha 不套用普通彩色视频的 Gamma 或色调映射。

## 精度与导出边界

- 交互时间体为 RGBA8，因此预览 Alpha 会正确舍入到 8-bit；它不等同于 10/12/16-bit 无损数据。
- 完整 `A_color + B_alpha` 可生成源显示分辨率、源时间线的 UInt16 Alpha sidecar，并记录尺寸、PTS、range、设置、字节序及文件哈希。
- `B_alpha`-only 的 gray10/12/16le 可以用于交互式白模预览和普通本机 RGBA8 工作流。
- 当前 B-only 分布式 RGBA8 renderer 仅支持不超过 8-bit 的 `B_alpha` 和不超过 8-bit 的输出。
- 当前 paired renderer 无法同时保留高于 8-bit 的颜色与 Alpha；相关高精度或分布式任务会在传输、调度或静默量化前明确拒绝。
- Straight 输出保持 RGB 不变；Premultiplied 输出只在最终输出阶段执行预乘。
- 对于原本已经预乘且 `Alpha = 0` 的输入，丢失的隐藏 RGB 无法恢复，程序会明确提示这一限制。

## 工程、缓存与分布式渲染

- 工程文件会分别保存 `A_color` 与 `B_alpha` 的 security-scoped bookmark、Alpha 模式、配对身份和全部外部 Alpha 设置。
- 缓存键同时包含两路源文件身份、Alpha 设置、同步/缩放策略与缓存版本。
- 使用缓存前会重新校验 `A_color`、`B_alpha`、sidecar 和 metadata 的 SHA-256；只检查文件存在不视为有效缓存。
- 分布式任务会传递并分别校验两路文件，Host 与 Worker 使用同一套 PTS 对齐、Alpha 归一化、尺寸和位深策略。
- 源分辨率 paired volume 与高精度 sidecar 在分配前后都有内存预算检查；异常或超预算素材会明确拒绝。

## 测试

运行 macOS 主测试：

```bash
xcodebuild -project ChronoVolume.xcodeproj \
  -scheme ChronoVolume \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/ChronoVolumeTests \
  -only-testing:ChronoVolumeTests \
  test
```

安装 FFmpeg 后，测试会实际覆盖 MOV + FFV1/MKV、gray16le、YUV range、Worker 分段像素回读和高精度 Alpha sidecar 等集成路径。

## Windows Python 原型

仓库中的 `Python原型-Windows可用/` 保留了 Windows 10/11 可运行的 Python 原型、PowerShell 安装助手及中文说明。它与当前 macOS Swift 主程序是独立实现，不代表两端所有高级功能完全一致。

## 编码与保真边界

- Alpha 是否无损取决于源像素格式、解码路径、range、位深和输出编码器的共同能力。
- 有损压缩 `B_alpha` 会直接造成透明边缘断层、脏边或闪烁。
- 容器或编码名称通常不足以可靠判断 Straight / Premultiplied Alpha，应以明确的输入设置为准。
- 不支持目标 Alpha 位深的输出编码会被拒绝或要求显式降位深，不会冒充高精度输出。
- QuickTime Player 能否播放某个 MKV/FFV1 文件，不代表 FFmpeg 或 ChronoVolume 能否读取该文件。

## 相关项目

- [AlphaCheater](https://github.com/Drangeeeeeee/AlphaCheater)：将 RGBA 视频拆分为 `A_color` 颜色流与 `B_alpha` 灰度透明度流。

## 赞助与商业支持

如果 ChronoVolume 为你的个人创作、研究工作或商业产品创造了价值，欢迎自愿赞助本项目，支持后续维护、格式兼容、性能优化和文档完善。

赞助完全自愿，不是使用、修改或分发 ChronoVolume 的条件，也不会改变 MIT License 已授予的任何权利。即使不赞助，你仍然可以继续按照 MIT License 使用本项目。

如果企业需要定制功能、制作管线集成、分布式渲染部署、特殊编码格式支持或技术咨询，欢迎发送邮件至 [1336135638@qq.com](mailto:1336135638@qq.com) 与作者单独协商。

## License

ChronoVolume 使用 MIT License，详见 [LICENSE](LICENSE)。
