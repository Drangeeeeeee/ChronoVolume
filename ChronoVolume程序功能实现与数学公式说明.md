# ChronoVolume 程序功能、实现方式、数学公式与实际意义说明

## 1. 程序概述

ChronoVolume 是一个面向 macOS 的视频时间体可视化、切片、合成与导出工具。它的核心思想是把普通二维视频转换成三维“时空体”：

$$
V(x,y,t) = (R,G,B,A)
$$

其中 `x` 和 `y` 是视频帧内的空间坐标，`t` 是时间/帧序号，`R,G,B,A` 是该像素在该时刻的颜色与透明度。这样，视频不再只是沿时间播放的一串图像，而是一个可以旋转、切开、观察、变形、合成、导出的三维体数据。

程序主要由 SwiftUI 界面、AVFoundation 视频读写、Metal GPU 渲染与计算、项目文件管理、分布式导出服务组成。核心源码包括：

- `ChronoVolume/AppModel.swift`：主程序状态、视频加载、播放、渲染器连接。
- `ChronoVolume/VideoVolumeLoader.swift`：把视频解码并打包为三维体数据。
- `ChronoVolume/VolumeRenderer.swift` 与 `ChronoVolume/Shaders.metal`：3D 时间体渲染。
- `ChronoVolume/ChronoVolumeState.swift`：时间轴、切片、参考面、CPU 体数据定义。
- `ChronoVolume/CompositionModel.swift` 与 `ChronoVolume/CompositionRenderer.swift`：合成、图层、关键帧、表达式、摄像机、混合模式。
- `ChronoVolume/VideoExportHelper.swift` 与 `ChronoVolume/HighPrecisionExportKernels.metal`：本机导出、高精度 raw cache 导出、GPU/CPU fallback。
- `ChronoVolume/DistributedExportCoordinator.swift`、`ChronoVolume/WorkerServer.swift`、`ChronoVolume/WorkerJobExecutor.swift`：分布式渲染。
- `ChronoVolume/VolumeModifierRasterizer.swift` 与 `ChronoVolume/VolumeModifierKernels.metal`：体素变形、膨胀、扭曲、锥化、SDF 表面处理。

## 2. 程序主要功能

### 2.1 视频导入与时间体构建

程序支持导入一个或多个视频素材，并读取分辨率、帧数、FPS、bit depth、Alpha 状态和色彩配置。导入后，程序会把视频帧解码为 RGBA 数据，再把连续帧堆叠成三维体：

$$
\text{index}(x,y,t)=((tH+y)W+x)\times4
$$

其中 `W` 是宽度，`H` 是高度，`t` 是第几帧。每个体素保存 4 个通道：`R,G,B,A`。

### 2.2 2D 播放与基础时间轴

程序保留了普通视频播放能力，使用 `AVPlayer` 做 2D 播放，同时用 `CVDisplayLinkDriver` 或计时器驱动预览刷新。用户可以在时间轴上切换帧、播放/暂停、改变播放速率，并在不同切片和 3D 视图中同步当前帧。

### 2.3 3D 时间体预览

程序可以把时间体作为三维体积显示。用户可以：

- 旋转、缩放、平移观察时间体。
- 在 Alpha 体模式中用透明度作为体密度。
- 在像素体模式中保留块状体素感。
- 设置密度、亮度、采样步数、边缘平滑。
- 显示世界坐标轴、参考面、摄像机示意。
- 使用纯色、透明背景或棋盘格背景。

### 2.4 轴切片与参考面切片

程序支持两类切片：

1. 轴切片：固定 `T`、`X` 或 `Y` 中的一维，得到二维图像。
2. 参考面切片：用户通过 yaw、pitch、roll 定义任意切割平面，然后沿法线方向逐层扫描时间体。

轴切片可以生成典型的时空切片效果。例如：

- `T` 轴切片：普通视频帧，图像平面是 `X-Y`。
- `X` 轴切片：固定空间横坐标，图像平面是 `T-Y`。
- `Y` 轴切片：固定空间纵坐标，图像平面是 `X-T`。

参考面切片则允许用户从任意角度“切开”视频体，看到运动轨迹、透明轮廓和时间结构。

### 2.5 合成工作区

程序已经从单视频工具扩展为类似动态图形软件的合成系统：

- 支持多个素材、多个合成。
- 视频、模型、预合成都可以作为素材。
- 图层可拖入时间线并设置开始帧、持续时间、显隐、锁定、Solo。
- 图层支持位置、旋转、缩放、不透明度、渲染模式、混合模式。
- 支持预合成：多个图层可以打包为一个合成层，再嵌入其他合成。
- 支持多个摄像机，摄像机也作为时间线片段存在。

### 2.6 关键帧与表达式

图层和摄像机属性支持关键帧动画。图层属性包括：

- 位置 X/Y/Z
- 旋转 X/Y/Z
- 缩放
- 不透明度

摄像机属性包括：

- yaw、pitch、roll
- 位置 X/Y/Z
- 焦点 X/Y/Z
- 焦段
- 光圈

关键帧支持线性、缓入缓出、保持和贝塞尔插值。表达式系统支持 `frame`、`time`、`fps`、`value` 等变量，以及 `sin`、`cos`、`noise`、`clamp`、`lerp`、`pow` 等函数，也可以引用其他图层或摄像机属性。

### 2.7 体素修改器

程序提供针对时间体/模型体的变形能力，包括：

- 位移、旋转、缩放。
- Alpha 边界膨胀。
- Surface SDF 表面膨胀/侵蚀。
- Fractured Surface 破碎表面效果。
- Y 轴扭曲。
- X/Z 方向锥化。
- 镜像。

普通仿射与形变优先走 Metal GPU；Surface SDF 和破碎表面在体素数量允许时使用 CPU 距离场算法，超过限制时使用 fallback。

### 2.8 导出系统

导出支持多种路径：

- T 轴普通导出可在条件满足时使用 `AVAssetExportSession` 直通导出。
- 轴切片和参考面切片优先使用 Metal compute kernel 直接写入 `CVPixelBuffer`。
- GPU 不可用时回退到 CPU 渲染。
- 模型切片可以通过三角面与平面求交直接栅格化。
- 高精度导出使用原始源视频或 raw cache，避免只依赖低分辨率代理体。
- 导出支持 Alpha、棋盘格合成、偶数尺寸 padding、bit depth、色彩配置。

### 2.9 分布式渲染

程序支持多台 Mac 作为 Worker 协同导出。主机负责：

- 计算源文件 SHA-256。
- 检查 Worker 是否已有源文件。
- 通过独立 TCP 流传输大文件。
- 让 Worker 预热 raw cache。
- 按输出帧范围拆分任务。
- 收集 Worker 输出片段和 metadata。
- 拼接最终视频。

Worker 负责：

- 接收源文件。
- 维护本地源文件缓存和 raw cache。
- 执行分段导出。
- 回报进度、状态、错误和结果路径。

## 3. 数据结构与处理流程

### 3.1 视频到体数据的转换流程

视频导入流程大致如下：

1. 使用 `AVURLAsset` 打开文件。
2. 读取视频轨道、自然尺寸、`preferredTransform`、时长、FPS。
3. 根据方向变换得到实际显示尺寸。
4. 按最大宽高限制计算目标尺寸。
5. 依次尝试 `AVAssetReader`、`AVAssetImageGenerator`、`ffmpeg` 解码帧。
6. 使用 Core Image 把每帧渲染为 RGBA8。
7. 修复可能的预乘 Alpha 边缘。
8. 判断是否存在有效 Alpha。
9. 按空间缩放比例压缩时间深度。
10. 打包为 `LoadedVolume` 和 `CPUVolume`。

尺寸缩放公式为：

$$
s=\min\left(1,\frac{W_{\max}}{W},\frac{H_{\max}}{H}\right)
$$

$$
W'=\mathrm{round}(Ws),\quad H'=\mathrm{round}(Hs)
$$

为了让体数据在空间和时间上比例更协调，程序还会按空间缩放比例缩短时间深度：

$$
D'=\min\left(F,\mathrm{round}(F\cdot s)\right)
$$

其中 `F` 是实际解码帧数，`D'` 是三维体的深度。深度重采样的帧索引为：

$$
k_i=\mathrm{round}\left(\frac{i}{D'-1}(F-1)\right)
$$

### 3.2 坐标系统

程序中体数据有两套常用坐标：

1. 体素坐标：

$$
x\in[0,W-1],\quad y\in[0,H-1],\quad t\in[0,D-1]
$$

2. 居中局部坐标：

$$
p=(x,y,t)-\frac{(W-1,H-1,D-1)}{2}
$$

3D 渲染时还会把体缩放到 `[-0.5,0.5]` 附近的标准立方体空间：

$$
u=\frac{x}{W-1}-0.5,\quad v=\frac{y}{H-1}-0.5,\quad w=\frac{t}{D-1}-0.5
$$

为了保持宽、高、时间深度的显示比例，程序使用归一化体缩放：

$$
S_v=\left(\frac{W}{M},\frac{H}{M},\frac{D}{M}\right),\quad M=\max(W,H,D)
$$

## 4. 3D 渲染实现与数学公式

### 4.1 模型、视图、投影矩阵

每个时间体图层最终通过模型矩阵、视图矩阵和投影矩阵送入 Metal：

$$
P_{\text{clip}}=P\cdot V\cdot M\cdot P_{\text{local}}
$$

图层模型矩阵由位移、旋转和缩放组成：

$$
M=T\cdot R_z\cdot R_y\cdot R_x\cdot S
$$

其中旋转矩阵使用轴角公式。给定单位轴 `a=(x,y,z)`、角度 `theta`：

$$
R=
\begin{bmatrix}
c+x^2(1-c)&xy(1-c)+zs&xz(1-c)-ys&0\\
xy(1-c)-zs&c+y^2(1-c)&yz(1-c)+xs&0\\
xz(1-c)+ys&yz(1-c)-xs&c+z^2(1-c)&0\\
0&0&0&1
\end{bmatrix}
$$

其中：

$$
c=\cos\theta,\quad s=\sin\theta
$$

摄像机焦段转换为垂直视场角：

$$
\mathrm{FOV}_y=2\arctan\left(\frac{h_s}{2f}\right)
$$

源码中传感器高度 `h_s=24`，`f` 是焦段。透视投影矩阵使用右手坐标系：

$$
y_s=\frac{1}{\tan(\mathrm{FOV}_y/2)},\quad x_s=\frac{y_s}{\mathrm{aspect}}
$$

$$
P=
\begin{bmatrix}
x_s&0&0&0\\
0&y_s&0&0\\
0&0&-\frac{f_a+n}{f_a-n}&-1\\
0&0&-\frac{2f_an}{f_a-n}&0
\end{bmatrix}
$$

其中 `n` 是 near plane，`f_a` 是 far plane。

### 4.2 焦点锁定摄像机

当摄像机锁定焦点时，程序根据位置和焦点构造 look-at 摄像机矩阵：

$$
\vec f=\frac{target-position}{\|target-position\|}
$$

$$
\vec r=\frac{\vec f\times \vec{up}}{\|\vec f\times \vec{up}\|},\quad
\vec u=\frac{\vec r\times \vec f}{\|\vec r\times \vec f\|}
$$

如果摄像机有 roll，会再绕 `forward` 方向旋转 `right` 和 `up`。最终摄像机世界矩阵为：

$$
C=
\begin{bmatrix}
r_x&r_y&r_z&0\\
u_x&u_y&u_z&0\\
-f_x&-f_y&-f_z&0\\
p_x&p_y&p_z&1
\end{bmatrix}
$$

视图矩阵为：

$$
V=C^{-1}
$$

### 4.3 射线与体盒求交

3D 体渲染不是直接画体素点，而是对每个可见片元从摄像机发出射线，在标准立方体中采样体数据。

摄像机位置先变换到体局部空间：

$$
C_l=M^{-1}C_w
$$

射线方向为：

$$
\vec d=\frac{P_l-C_l}{\|P_l-C_l\|}
$$

其中 `P_l` 是当前片元在体局部空间的位置。射线与盒子 `[-0.5,0.5]^3` 的求交使用 slab 方法：

$$
t_0=\frac{b_{\min}-r_o}{r_d},\quad t_1=\frac{b_{\max}-r_o}{r_d}
$$

$$
t_{\min}=\max(\min(t_0,t_1)_x,\min(t_0,t_1)_y,\min(t_0,t_1)_z)
$$

$$
t_{\max}=\min(\max(t_0,t_1)_x,\max(t_0,t_1)_y,\max(t_0,t_1)_z)
$$

当：

$$
t_{\max}\ge \max(t_{\min},0)
$$

说明射线与体盒相交。

### 4.4 体渲染采样与 Alpha 合成

连续体渲染沿射线均匀采样：

$$
\Delta t=\frac{t_{\max}-t_{\min}}{N}
$$

采样点为：

$$
p_i=r_o+r_d(t_{\min}+i\Delta t)
$$

局部坐标转换为 3D 纹理坐标：

$$
uvw=(p_x+0.5,\ 1-(p_y+0.5),\ p_z+0.5)
$$

如果使用 Alpha 体：

$$
\alpha_s=A_s
$$

如果使用像素亮度作为密度：

$$
\alpha_s=\max(R_s,G_s,B_s)
$$

每次采样的有效透明度为：

$$
\alpha_i=\mathrm{clamp}(\alpha_s\cdot density\cdot \Delta t\cdot 8,0,1)
$$

颜色会乘以亮度参数：

$$
C_i=RGB_s\cdot brightness
$$

程序采用前向 Alpha 合成：

$$
C_{acc}=C_{acc}+C_i\alpha_i(1-A_{acc})
$$

$$
A_{acc}=A_{acc}+\alpha_i(1-A_{acc})
$$

当：

$$
A_{acc}>0.995
$$

就提前终止采样，以节省 GPU 计算。

### 4.5 边缘平滑

边缘平滑时，程序对中心采样和 6 个轴向邻居采样加权：

$$
C_{smooth}=0.5C_0+\frac{0.5}{6}\sum_{i=1}^{6}C_i
$$

这个处理可以减轻透明边缘发黑、锯齿和体素边缘断裂。

### 4.6 抖动

导出或显示到 8-bit 颜色时，为了减轻色带，程序给 RGB 加入非常小的伪随机扰动：

$$
d=\frac{\mathrm{fract}(\sin(p\cdot(12.9898,78.233))\cdot43758.5453)-0.5}{255}
$$

$$
C'=\mathrm{clamp}(C+d,0,1)
$$

### 4.7 体素块模式

体素块模式不是按固定步数累计所有采样点，而是沿射线跨过不同体素时，每个体素只累计一次。这样能保留明显的像素/体素结构，用于表现“时间体是由离散帧和像素构成的”这种视觉语言。

## 5. 切片实现与数学公式

### 5.1 轴切片

轴切片固定某一维，然后把另外两维映射到输出图像。

固定 `T`：

$$
x=u(W-1),\quad y=v(H-1),\quad t=k
$$

固定 `X`：

$$
x=k,\quad y=v(H-1),\quad t=u(D-1)
$$

固定 `Y`：

$$
x=u(W-1),\quad y=k,\quad t=v(D-1)
$$

其中 `(u,v)` 是输出图像中的归一化坐标。

### 5.2 参考面定义

参考面由 yaw、pitch、roll 构成旋转矩阵：

$$
R=R_z(roll)\cdot R_x(pitch)\cdot R_y(yaw)
$$

再得到平面局部坐标轴：

$$
\vec u=R(1,0,0),\quad \vec v=R(0,1,0),\quad \vec n=R(0,0,1)
$$

其中 `u`、`v` 是切片平面内两个方向，`n` 是法线方向。

### 5.3 参考面范围计算

程序把体数据 8 个角点投影到 `u/v/n` 三个方向上：

$$
p_u=p\cdot u,\quad p_v=p\cdot v,\quad p_n=p\cdot n
$$

然后得到：

$$
u_{\min},u_{\max},v_{\min},v_{\max},n_{\min},n_{\max}
$$

输出切片宽高为：

$$
W_o=\lceil u_{\max}-u_{\min}\rceil
$$

$$
H_o=\lceil v_{\max}-v_{\min}\rceil
$$

切片数量为：

$$
N_s=\lceil n_{\max}-n_{\min}\rceil
$$

### 5.4 参考面像素到体素坐标

输出像素 `(i,j)` 对应：

$$
f_u=u_{\min}+\frac{i+0.5}{W_o}(u_{\max}-u_{\min})
$$

$$
f_v=v_{\min}+\frac{j+0.5}{H_o}(v_{\max}-v_{\min})
$$

第 `k` 张切片的法线距离为：

$$
d=
\begin{cases}
\frac{n_{\min}+n_{\max}}{2}, & N_s=1\\
n_{\min}+\frac{k}{N_s-1}(n_{\max}-n_{\min}), & N_s>1
\end{cases}
$$

切片上的三维点为：

$$
p=u f_u+v f_v+n d
$$

再转换到体素坐标：

$$
q=p+\frac{(W-1,H-1,D-1)}{2}
$$

如果 `q` 落在体数据范围内，就进行最近邻或三线性采样；否则输出透明。

### 5.5 三线性插值

高精度参考面导出和 CPU fallback 使用三线性插值。设：

$$
x_0=\lfloor x\rfloor,\quad x_1=x_0+1,\quad f_x=x-x_0
$$

`y`、`t` 同理。八个角点颜色为：

$$
C_{000},C_{100},C_{010},C_{110},C_{001},C_{101},C_{011},C_{111}
$$

先沿 X 插值：

$$
C_{00}=lerp(C_{000},C_{100},f_x)
$$

$$
C_{10}=lerp(C_{010},C_{110},f_x)
$$

$$
C_{01}=lerp(C_{001},C_{101},f_x)
$$

$$
C_{11}=lerp(C_{011},C_{111},f_x)
$$

再沿 Y 插值：

$$
C_0=lerp(C_{00},C_{10},f_y)
$$

$$
C_1=lerp(C_{01},C_{11},f_y)
$$

最后沿 T 插值：

$$
C=lerp(C_0,C_1,f_t)
$$

其中：

$$
lerp(a,b,t)=a+(b-a)t
$$

## 6. 合成系统实现

### 6.1 图层渲染流程

合成渲染时，程序会根据当前帧筛选活动图层：

$$
startFrame\le frame<startFrame+duration
$$

如果存在 Solo 图层，则只渲染 Solo 图层。预合成会递归展开，并把父级变换矩阵继续传给子合成：

$$
M_{childWorld}=M_{parent}\cdot M_{child}
$$

最终每个图层会变成一个 `CompositionRenderLayer`，包含：

- 素材 ID
- 3D 纹理 ID
- 变换矩阵
- 混合模式
- 不透明度
- 体渲染模式
- 修改器状态
- 轨道遮罩信息

### 6.2 混合模式

程序通过 Metal render pipeline 的 blend state 实现混合模式。

正常模式使用预乘 Alpha 合成：

$$
C_{out}=C_s+C_d(1-A_s)
$$

$$
A_{out}=A_s+A_d(1-A_s)
$$

相加模式近似为：

$$
C_{out}=C_s+C_d
$$

屏幕模式使用目标颜色乘以 `1-sourceColor` 的 blend 因子，视觉效果接近：

$$
C_{out}=1-(1-C_s)(1-C_d)
$$

正片叠底使用目标颜色作为源颜色因子，视觉效果接近：

$$
C_{out}=C_sC_d+C_d(1-A_s)
$$

轨道遮罩模式不会直接输出遮罩层颜色，而是把遮罩层 Alpha 用作下方图层的裁切因子。

### 6.3 轨道遮罩

轨道遮罩会沿当前图层射线对应的世界方向，再投射到遮罩体局部空间，采样遮罩 Alpha：

$$
m=\max_i \alpha_i\cdot opacity_{matte}
$$

然后裁切当前层：

$$
C'=Cm,\quad A'=Am
$$

当：

$$
m\le \frac{1}{255}
$$

片元会被丢弃。

## 7. 关键帧与表达式数学

### 7.1 线性关键帧

设当前帧为 `f`，相邻关键帧为 `(f_0,v_0)` 和 `(f_1,v_1)`：

$$
t=\mathrm{clamp}\left(\frac{f-f_0}{f_1-f_0},0,1\right)
$$

$$
v=v_0+(v_1-v_0)t
$$

### 7.2 缓入缓出

缓入缓出使用 smoothstep：

$$
t'=t^2(3-2t)
$$

$$
v=v_0+(v_1-v_0)t'
$$

### 7.3 保持插值

保持插值不做中间过渡：

$$
v=v_0
$$

直到到达下一关键帧才跳变。

### 7.4 三次贝塞尔插值

贝塞尔曲线使用两个控制点：

$$
P_1=(x_1,y_1),\quad P_2=(x_2,y_2)
$$

曲线坐标为：

$$
B(t)=3(1-t)^2tP_1+3(1-t)t^2P_2+t^3
$$

由于关键帧输入是线性时间 `x`，程序先用二分法求出满足：

$$
B_x(t)=x
$$

的参数 `t`，再取：

$$
y=B_y(t)
$$

作为插值比例。

### 7.5 表达式求值

表达式支持算术优先级：

1. 括号与函数
2. 一元正负
3. 幂运算
4. 乘、除、取模
5. 加、减

内置变量包括：

$$
frame=f,\quad time=\frac{f}{fps}
$$

还包括 `fps`、`value`、`pi`、`e`。表达式结果会根据属性类型转换，例如旋转属性在表达式中以角度显示，内部再转回弧度：

$$
radian=degree\cdot\frac{\pi}{180}
$$

### 7.6 确定性噪声

表达式中的 `noise(x, seed)` 使用确定性噪声：

$$
raw(x,seed)=2\cdot fract(\sin(12.9898x+78.233seed)\cdot43758.5453)-1
$$

再对相邻整数点做 smoothstep 插值：

$$
s=f^2(3-2f)
$$

$$
noise=raw(\lfloor x\rfloor)(1-s)+raw(\lfloor x\rfloor+1)s
$$

这样每次打开项目得到的噪声动画是稳定可复现的。

## 8. 体素修改器实现与数学公式

### 8.1 逆向映射思想

体素变形使用逆向映射：对输出体中的每个体素，反推它应该从输入体的哪个位置采样。

输出体素先归一化到：

$$
p=\left(\frac{x}{W-1},\frac{y}{H-1},\frac{z}{D-1}\right)-0.5
$$

如果有虚拟透明边界，还会扩大采样空间：

$$
p'=c+(p-c)\cdot outsetScale
$$

多个修改器按反向顺序应用：

$$
p_{src}=F_1^{-1}(F_2^{-1}(...F_n^{-1}(p')...))
$$

最后转换回体素坐标并线性采样。

### 8.2 仿射逆变换

每个修改器有平移、旋转、缩放构成的仿射矩阵：

$$
A=T\cdot R_z\cdot R_y\cdot R_x\cdot S
$$

逆向采样时使用：

$$
p'=A^{-1}p
$$

### 8.3 膨胀/收缩

膨胀以某个中心 `c` 为参考，并考虑体比例 `s_v`：

$$
q=(p-c)\cdot s_v
$$

$$
q'=q-\frac{q}{\|q\|}\cdot inflate
$$

$$
p'=c+\frac{q'}{s_v}
$$

由于这是逆向映射，正向看起来是体向外膨胀或向内收缩。

### 8.4 Y 轴扭曲

程序把垂直位置归一化为：

$$
h=\mathrm{clamp}(2p_y,-1,1)
$$

扭曲角度：

$$
\theta=-twistY\cdot h
$$

然后在 XZ 平面旋转：

$$
x'=x\cos\theta-z\sin\theta
$$

$$
z'=x\sin\theta+z\cos\theta
$$

### 8.5 锥化

X/Z 方向锥化为：

$$
x'=\frac{x}{1+taperX\cdot h}
$$

$$
z'=\frac{z}{1+taperZ\cdot h}
$$

分母会被限制在一个很小的正数以上，防止数值发散。

### 8.6 SDF 表面膨胀

Surface SDF 模式先用 Alpha 判断体素是否被占用：

$$
occupied = A>8
$$

然后建立到占用区域或空区域的平方距离场：

$$
d^2(p)=\min_{q\in S}\|p-q\|^2
$$

膨胀时，空体素如果满足：

$$
d(p)\le r
$$

就被填充。边缘覆盖度为：

$$
coverage=\mathrm{clamp}(r-d(p)+1,0,1)
$$

收缩时，占用体素根据到空区域的距离决定保留程度：

$$
keep=\mathrm{clamp}(d_{empty}(p)-r+1,0,1)
$$

破碎表面模式会额外叠加多尺度噪声、边界邻近度和局部半径变化，形成不均匀的裂纹与破碎边界。

## 9. 导出系统实现

### 9.1 普通导出

普通切片导出会创建 `AVAssetWriter`、`AVAssetWriterInput` 和 `AVAssetWriterInputPixelBufferAdaptor`，逐帧写入 `CVPixelBuffer`：

$$
t_{video}=frameIndex\cdot\frac{1}{fps}
$$

如果导出保留 Alpha，优先使用 ProRes 4444；如果不保留 Alpha 且不是高 bit depth/HDR，则使用 H.264。

### 9.2 Alpha 合成

如果保留 Alpha：

$$
out=(R,G,B,A)
$$

如果不保留 Alpha 且显示棋盘格：

$$
RGB_{out}=RGB_{bg}(1-A)+RGB_sA,\quad A_{out}=1
$$

如果不保留 Alpha 且不显示棋盘格：

$$
RGB_{out}=RGB_sA,\quad A_{out}=1
$$

### 9.3 GPU 轴切片导出

轴切片导出通过 `axisSliceKernel` 直接把 3D 纹理采样结果写入输出 2D 纹理，再由 `CVPixelBuffer` 写入视频。这样避免 CPU 逐像素循环，速度更高。

### 9.4 GPU 参考面导出

参考面导出通过 `planeSliceKernel` 或高精度 raw kernel，把每个输出像素映射回三维体坐标：

$$
p=u f_u+v f_v+n d
$$

再采样源体或 raw cache。

### 9.5 高精度 X/Y 轴重建

高精度 X/Y 轴导出不依赖代理体，而是读取原始尺寸视频帧或 raw cache。以 X 轴为例，固定源图像的 `x`，输出帧横向是时间，纵向是 `y`：

$$
out(t,y)=src_t(x,y)
$$

Metal kernel 中，一个批次对应多个固定 `x` 切片，写入 2D texture array，随后批量复制到 PixelBuffer。

Y 轴同理：

$$
out(x,t)=src_t(x,y)
$$

### 9.6 高精度参考面 raw cache

参考面 raw cache 导出把源视频预解码为连续 BGRA 字节。Metal kernel 对每个输出像素计算三维坐标 `(x,y,t)`，再用三线性插值读取 raw cache。这样可以保持接近源视频原始分辨率的切片质量。

### 9.7 模型直接切片

如果素材是 3D 模型，程序可以直接计算三角形与切片平面的交线。对三角形三个点：

$$
d_i=p_i\cdot n-d
$$

如果边的两个端点位于平面两侧，则交点参数为：

$$
\lambda=\frac{d_0}{d_0-d_1}
$$

$$
p=p_0+(p_1-p_0)\lambda
$$

交线再投影到 `u/v` 平面，栅格化为二维切片。GPU 版本会先用三角形在法线方向的范围做预剔除，减少无效求交。

## 10. 分布式渲染实现

### 10.1 任务拆分

分布式导出的核心是把完整输出帧范围拆成多个片段：

$$
[0,N-1]\rightarrow [a_0,b_0],[a_1,b_1],...,[a_k,b_k]
$$

每个 Worker 只负责其中一个或多个连续片段。片段导出完成后，程序用 metadata 记录：

- jobID
- segmentIndex
- axis
- outputStartFrame
- outputEndFrame
- outputWidth / outputHeight
- fps
- codec
- 文件大小

### 10.2 源文件一致性

主机计算源文件 SHA-256：

$$
hash=SHA256(fileBytes)
$$

Worker 以 hash 作为缓存键，避免重复传输同一个大视频。若 Worker 缺少源文件，主机会通过控制端口加 1 的 TCP 端口进行大文件流式传输。

### 10.3 Worker 执行流程

Worker 服务提供 `/hello`、`/capabilities`、`/source/check`、`/source/prepare`、`/job/start`、`/job/progress`、`/job/result` 等接口。收到任务后，`WorkerJobExecutor` 会调用：

`VideoExportHelper.exportHighPrecisionDistributedSegment(...)`

来导出指定帧段。Worker 的批次内存预算按物理内存估算：

$$
budget=\mathrm{clamp}\left(\frac{RAM}{5},768MB,3GB\right)
$$

这样能在不同机器上自动选择更合理的高精度批次大小。

## 11. 项目文件与缓存机制

### 11.1 项目保存

项目文件后缀为 `.CV`，由 `ChronoVolumeProjectDocument` 编码保存。内容包括：

- 主视频记录。
- 当前应用状态。
- 导出设置。
- 分布式设置。
- 合成素材、图层、关键帧、摄像机、预合成。
- 自动保存来源路径和时间。

项目文件带格式版本号：

$$
formatVersion=2
$$

打开旧项目时会执行迁移逻辑，保证兼容。

### 11.2 缓存

程序使用多级缓存：

- 预览体缓存：用于实时交互。
- raw cache：用于高精度切片和分布式 Worker。
- 高精度缓存：用于保留源视频原尺寸/Alpha 的导出。
- 修改体 GPU texture cache：用于体素修改器的交互预览和导出。
- Worker 源文件缓存：避免多次上传大文件。

缓存状态会出现在媒体管理器和缓存策略面板中，用户可以检查缺失、过期、大小和清理状态。

## 12. 实际意义

### 12.1 把时间可视化为空间

普通视频只能按时间顺序观看，ChronoVolume 把时间变成三维空间中的一个维度。运动、停顿、透明变化、轨迹和节奏都可以像物体一样被观察。这对理解视频中的时间结构非常有价值。

例如，一个快速移动的点在普通视频里只是逐帧移动；在时间体里，它会形成一条连续轨迹。用户可以从不同方向切开这条轨迹，分析速度、方向和形变。

### 12.2 提供新的影像创作方式

时间切片本身是一种强烈的视觉表达。固定空间坐标观察时间，会产生普通剪辑软件很难得到的图案、拖影、时间纹理和动态图形素材。程序的参考面切片、3D 体渲染、摄像机动画和合成系统，让这种效果可以被系统化创作，而不是只靠一次性脚本生成。

### 12.3 连接视频、3D 和动态图形

ChronoVolume 把视频帧当作体数据，把图层当作 3D 对象，把摄像机和关键帧引入合成工作区。这使它介于视频编辑、三维体渲染、动态图形和科学可视化之间。它可以处理传统视频，也可以处理 Alpha 视频、模型体素化结果和预合成。

### 12.4 支持高质量与大规模输出

预览阶段使用代理体保证交互流畅，导出阶段可以切换到 raw cache 或源视频原尺寸重建。分布式渲染又让高分辨率、长时间轴、任意参考面切片这类重任务可以拆到多台机器上完成。这使程序不仅能做实验性预览，也能产出可交付的视频文件。

### 12.5 具有分析价值

除了艺术创作，时间体也适合做运动分析、透明素材检查、视频异常观察、时序结构研究。例如：

- 检查 Alpha 边缘是否有黑边。
- 观察物体运动轨迹是否连续。
- 比较不同帧之间的空间变化。
- 分析固定截面随时间变化的纹理。
- 将复杂视频变成可测量的几何结构。

## 13. 总结

ChronoVolume 的本质是一个“视频时空体工作台”。它把视频从二维时间序列转换为三维体数据，再用 Metal 完成体渲染、切片、合成和高精度导出。程序中涉及的核心数学包括矩阵变换、透视投影、射线盒求交、体渲染 Alpha 积分、三线性插值、平面投影、关键帧插值、贝塞尔曲线、确定性噪声、距离场膨胀和分布式任务划分。

它的实际意义在于：让用户不仅能播放视频，还能从空间角度理解和创作时间；不仅能预览效果，还能通过高精度缓存和分布式渲染把实验性时间体效果真正导出为可用作品。
