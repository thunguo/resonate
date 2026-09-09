# 开发说明

## 工程结构

| 目录 | 职责 |
| --- | --- |
| `App/Views`、`App/Design` | SwiftUI 页面、配色和基础控件 |
| `App/Playback` | AVQueuePlayer、队列状态、锁屏控制和音频会话 |
| `App/Infrastructure` | 账号、SwiftData、缓存、下载和系统接入 |
| `Packages/MusicCore` | 音乐服务、AI 协议、领域模型、歌词与编排校验 |
| `Shared`、`Widget` | App Intents、小组件、共享摘要和隐私 API 声明 |
| `Config` | 构建配置、Info.plist 和 entitlements |
| `Tests`、`UITests` | 原生播放回归与界面测试 |

`MusicCore` 没有第三方 Swift 依赖。主 App 使用 SwiftUI、SwiftData、AVFoundation 和 MediaPlayer，最低部署版本为 iOS 18。

## 构建与测试

在仓库根目录运行：

```sh
swift test --package-path Packages/MusicCore

xcodebuild -project Yuyin.xcodeproj -scheme Yuyin \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Yuyin.xcodeproj -scheme Yuyin \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

将测试设备名称替换为已安装的模拟器。核心协议测试使用固定响应，UI 测试使用内存数据；测试不会发送验证码、修改真实歌单或产生模型费用。播放回归使用本地无声 WAV 驱动实际 AVQueuePlayer。

UI 无障碍回归检查主要触控区域和控件描述。自动对比度扫描单独作为诊断，在 Scheme 的 Test 环境变量中设置 `YUYIN_CONTRAST_AUDIT=1` 可启用；扫描结果包含系统遮挡区域，需结合截图人工复核。标准测试通过不代表全部界面已完成无障碍验收。

只读音乐服务探测：

```sh
swift run --package-path Packages/MusicCore MusicProbe
```

它会请求公共搜索、详情、歌词、推荐与播放资源信息，不下载音频，不执行账号写入。其结果不能替代真实登录、会员播放、模型调用或真机后台测试。

## 诊断与回归记录

设置中的“诊断与反馈”可预览和导出本机白名单计时，默认不上传。当前实测、模拟验证和待验收项目见 [质量记录](QUALITY.md)。

## 性能验收

在 Release 或 `PersonalRelease` 构建中，用 Instruments 的 SwiftUI、Time Profiler、Animation Hitches 和 App Launch 模板检查实际设备。先预热页面，再记录多次进入的内容呈现时间；首次迁移、首次登录和全新远程搜索分开统计。核心测试验证缓存命中、请求合并、账号隔离与大歌单完整性，不能代替真机帧率和网络条件验收。

开发预览使用示例音乐，不会代表真实账号的缓存规模。冷启动目标为已使用用户首页可操作 P95 ≤800 ms，内存命中页面 ≤100 ms，磁盘缓存首批内容 ≤200 ms；这些是验收目标，不是对外承诺的实测成绩。

真机数据读取基准可使用 `YuyinPerformance` scheme，只构建主 App 和原生测试，不申请 UI 测试运行器的额外 App ID。使用 `PersonalRelease`、自己的 Team 和设备，附加 `ENABLE_TESTABILITY=YES`，选择 `YuyinTests/PerformanceTests`。测试在独立临时数据库中生成一万首曲目，采样 30 次；输出的 P95 仅表示数据层耗时，不包含完整页面绘制或音频网络延迟。

## 修改工程配置

`project.yml` 是工程配置来源，生成的 `Yuyin.xcodeproj` 一并提交，方便直接打开。修改配置或新增文件后，用 XcodeGen 重新生成并检查差异：

```sh
xcodegen generate
```

个人 Team 和 Bundle Identifier 的本地调整不要提交。若需要长期保留自定义标识，应同时更新 `project.yml` 与工程，避免重新生成时恢复默认值。

宿主测试 `YuyinTests` 通过主 App 使用 MusicCore。不要重复添加 MusicCore 产品依赖，否则 Xcode 可能改用动态包框架，改变测试宿主的链接方式。

## 预览

在 Scheme 的 Run → Arguments 中添加 `--preview`，使用内存中的示例音乐库。只有 DEBUG 构建支持预览，普通启动读取真实账号状态。

| 参数 | 用途 |
| --- | --- |
| `--dark` | 深色外观 |
| `--player` / `--library` / `--settings` | 直接打开对应页面 |
| `--home-guest` / `--home-signed-in` | 未登录或已登录但没有播放队列的首页 |
| `--home-empty` / `--home-syncing` / `--home-sync-failed` | 配合已登录状态检查空库、同步和失败 |
| `--ai-result` | 编排结果示例 |
| `--long-title` | 长标题布局 |
| `--reading-test` | 独立示例歌词与长队列，检查关闭再打开的位置恢复 |

发布或日常使用时清空预览参数。

## 数据与 AI

- 网易云收藏与歌单以远端为准。本机按账号保存镜像、历史、队列和偏好；写入成功后更新同步状态。
- 完整歌单读取 `trackIds` 或分页接口，保留缺失曲目的 ID。账号切换后拒收旧会话响应。
- Cookie、API Key 和敏感自定义请求头存入设备 Keychain；不写入源码或日志。服务端缓存与日志隔离仍需独立验证。
- 编排先检索真实候选、检查全曲可播放性，再交给模型筛选；本地校验 ID、时长、来源比例和固定项目。应用前再次检查队列是否变化。
- 导读只为实际取得的资料生成来源链接。没有进行音频信号分析，来源约束不能替代事实质量抽检。
- 模型请求从手机直达所选 HTTPS 服务，不发送音乐账号凭据，也不静默切换厂商。自定义服务支持 OpenAI 兼容 Chat Completions。
- 可清理缓存预算 300 MB（封面 260 MB、音乐资料 40 MB），已解码封面内存预算 64 MB，AI 编排保留最近 10 次。本机聆听统计可清除，不包含远程分析 SDK。

`MusicRepository` 统一管理账户内缓存、新鲜度和并发读取。页面订阅本地快照与更新；后台失败不丢弃已有内容。缓存过期检查由页面访问、进入前台和主动刷新触发，不定时轮询。

SwiftData 的大批量存储由独立 actor 执行。收藏与缓存歌单按曲目 ID 共享资料，旧收藏快照在迁移成功后仍保留；未知版本禁止覆盖。队列结构与进度检查点分别保存。

播放器维护当前项与一个待播放项，随机选择在准备时确定。顺序、插队、循环和固定项目由业务队列管理，预取失败不会中断当前曲目。播放资源仅在内存中按有效期复用。

智能预热优先固定及常听内容，最多准备 20 个歌单、200 张候选封面，每天预留流量预算 100 MB。需要非受限 Wi-Fi、正常温度、关闭低电量模式、充电中或电量高于 40%、可用空间大于 1 GB，并在前台空闲 10 秒后执行。预算采用请求上限预留，实际传输通常更少；前台操作与播放优先。系统变化会取消预热。

默认音乐 API 地址位于 `MusicService` 的初始化参数中。

## 系统能力

| 能力 | 当前状态 |
| --- | --- |
| 后台音频、AirPlay、锁屏控制 | 已接入统一播放器，仍需真实耳机、来电和网络切换验收 |
| 小组件与快捷指令 | 使用 App Intent 打开主 App 后播放；真机发现、刷新与冷启动需实测 |
| App Groups | Debug/Release 使用共享摘要；`PersonalDevice` / `PersonalRelease` 不申请该权限，不能跨扩展共享播放状态 |
| CarPlay | 系统音频模板位于独立 `CarPlay` 配置；需 Apple 音频 entitlement 和车载验证 |
| 离线下载 | 当前关闭；授权、逐曲资格及动态撤销机制完善后再开放 |

标准 App Group 为 `group.space.thunguo.yuyin`。修改时同步更新 `Config/App.entitlements`、`Config/CarPlay.entitlements` 与 `Shared/WidgetSnapshot.swift`，并为两个 target 配置一致的签名能力。

离线相关发行字段为 `YYOfflineDownloadEnabled` 和 `YYOfflineAuthorizationValidUntil`；配置开关不替代实际音乐授权。公开发行前仍需完成服务与音乐使用许可、隐私政策、数据披露和设备验收。

## 仓库约定

提交源码、资源、共享工程配置、测试、产品截图和维护文档。构建产物、用户设置、签名材料、密钥、日志及本地验收记录由 `.gitignore` 排除。
