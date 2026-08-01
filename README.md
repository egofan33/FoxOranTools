# FoxOranTools — Android APK 一键构建工具箱

面向 Flutter / React Native / Expo / Cordova / 原生 Android 项目的 Windows 本地构建脚本。自动准备便携版 JDK 17、Node.js、Android SDK、Flutter SDK，完成 Expo prebuild / Flutter build / Cordova build、Gradle 编译、zipalign 对齐与 APK 签名，全程针对国内网络环境做了镜像加速。

## 支持的项目类型

构建开始时脚本会询问「请问您的项目类型为」（1 Flutter / 2 Expo / 3 RN CLI / 4 原生 Android / 5 Cordova / 0 自动检测，回车默认自动检测），随后按所选类型对目录做特征校验，不匹配时弹窗列出缺失特征并重新选择——避免仅按目录自动检测时因选错目录而误判。

| 类型 | 识别特征 | 构建方式 |
|---|---|---|
| Flutter 项目 | `pubspec.yaml`（dependencies 内含 `flutter` + `sdk: flutter` 约束，environment 含 sdk/flutter 约束）+ `android\` 目录 | `flutter pub get` → `flutter build apk --release` → 重签名输出；缺少 `android\` 目录时自动 `flutter create` 补全 |
| Expo 项目 | `package.json` 含 `expo` 依赖，无 `android\` 目录 | 自动 `expo prebuild` 生成 android 工程后构建 |
| RN CLI 项目 | `package.json` 含 `react-native` 依赖 | 跳过 prebuild（已有 `android\` 目录时），直接 Gradle 构建 |
| 原生 Android Studio 项目 | 根目录有 `settings.gradle(.kts)` + `gradlew.bat`，无 `package.json`/`pubspec.yaml` | 跳过 Node 依赖与 prebuild，直接 Gradle 构建；支持多模块（自动扫描各模块 release APK） |
| Cordova 项目 | 项目根有 `config.xml`，或 `package.json` 含 cordova/cordova-android 依赖 | 自动安装 Cordova CLI（npm 镜像）→ JDK 按平台版本自适应（8/11/17）→ `cordova platform add android` 自愈（尊重项目锁定版本）→ `cordova requirements` 检测补装缺失 SDK → release 签名输出 + debug 直出，均复制到 `release\` |

> Expo/RN 混用项目（RN 中安装了 `expo` / `expo-modules-core`）：选 Expo 或 RN CLI 均可通过校验；自动检测按 Expo 处理并给出提示。是否执行 prebuild 以实际依赖为准，混用项目两种选择都能正确构建。
>
> 原生项目要求 AGP 兼容 JDK 17（AGP 8.x 推荐）。使用 AGP 7.x 及更早版本的老项目需要 JDK 11，本脚本固定提供 JDK 17，暂不适合。

## 功能一览

| 功能 | 说明 |
|---|---|
| 便携依赖自动安装 | JDK 17（Adoptium Temurin，多源轮询）、Node.js（按 `.nvmrc` / `engines.node` 选版本）、Android SDK（cmdline-tools + platform + build-tools）、Flutter SDK（stable 通道，优先复用系统已有）、MinGit（Flutter 依赖，系统无 git 时自动下载） |
| 全自动构建 | 依赖安装 → Expo prebuild / `flutter build apk --release` / `cordova build android`（按项目类型）→ `gradlew assembleRelease` → zipalign → apksigner 签名 → 输出到 `release\` |
| 缓存清理 | 停止 Gradle Daemon 并清理 Android / Flutter(`build`、`.dart_tool`) / Expo / Metro / Gradle / CMake(`.cxx`) / Cordova(`platforms`) 缓存 |
| 国内镜像加速 | 阿里云 Maven 仓库（含连通性探测）、腾讯云 Android SDK、华为云/腾讯云 Gradle Wrapper、Flutter 镜像（storage.flutter-io.cn + pub.flutter-io.cn）、GitHub git 依赖 gh-proxy 重写（url.insteadOf 会话级注入）、gh-proxy GitHub 加速 |
| 构建预检自愈 | node_modules junction 健康检查与修复、transforms 缓存残缺条目清理、CMake `.cxx` 过期缓存检测重建、系统内存预检 |
| 长路径防护 | 短路径 `GRADLE_USER_HOME`（默认 `C:\APKTools\g\{项目短标识}`）+ 系统 `LongPathsEnabled` 检测（管理员运行时自动启用） |
| 签名材料管理 | 首次构建自动生成 4096 位 RSA keystore 与随机密码（alias/dname 默认按项目包名与应用名自动派生，可在 config.json `signing` 节强制指定），后续自动复用；自动向 `.gitignore` 追加 `.signing/` 防泄漏 |

## 快速开始

1. 双击 `build.bat`，出现彩色菜单：
   - `[1] 全自动构建` —— 下载依赖 + 编译 + 签名输出 APK
   - `[2] 清理缓存` —— 停 Daemon 并清理构建缓存
   - `[3] 配置环境` —— 仅安装/检查 JDK、Node.js、Android SDK（Flutter 项目含 Flutter SDK 与便携 git）
2. 选择「全自动构建」后会先询问项目类型（回车默认自动检测），再按类型校验项目目录特征。
3. 脚本会自动检测项目根目录（含 `package.json`、`pubspec.yaml` 或 `android` 文件夹）；检测不到或特征与所选类型不符时弹窗手动选择。
4. 构建产物：`{项目}\release\app-release.apk`（Cordova 项目另有 `app-debug.apk` 调试版；重名自动加时间戳），并输出 SHA-256。
5. 构建过程日志同步写入 `C:\APKTools\.cache\{项目名}\logs\build-*.log`，构建失败排查时可提供该文件。

也可以命令行直接调用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File BuildCore.ps1 -Action Build      # 构建
powershell -NoProfile -ExecutionPolicy Bypass -File BuildCore.ps1 -Action Clean      # 清理缓存
powershell -NoProfile -ExecutionPolicy Bypass -File BuildCore.ps1 -Action SetupEnv   # 仅配置环境
```

## 配置（config.json）

复制 `config.example.json` 为 `config.json` 后按需修改，未配置项使用内置默认值。常用项：

```jsonc
{
  "android": { "acceptLicenses": false },        // true 则跳过许可证交互确认
  "paths": {
    "globalToolsRoot": "C:\\APKTools",           // 全局工具目录（保持短路径）
    "mobileSubPath": "",                          // RN/Expo 代码在子目录时填，如 "apps/mobile"
    "gradleUserHome": "C:\\APKTools\\g\\{project}" // Gradle 缓存路径模板，勿改长
  },
  "signing": { "keyAlias": "", "dname": "" },   // 留空=按项目自动派生签名身份
  "flutter": {                                // Flutter 镜像（SDK 下载与 pub 依赖）
    "storageBaseUrl": "https://storage.flutter-io.cn",
    "pubHostedUrl": "https://pub.flutter-io.cn"
  }
}
```

全局目录布局（按项目隔离缓存）：

```
C:\APKTools\
├── jdk\17\                # 便携 JDK
├── node\{version}\        # 便携 Node.js
├── android-sdk\           # Android SDK
├── flutter\{version}\     # 便携 Flutter SDK（stable）
├── git\mingit\            # 便携 MinGit（Flutter 工具链依赖，系统无 git 时才下载）
├── g\{项目短标识}\        # GRADLE_USER_HOME（短路径，防 260 字符上限）
└── .cache\{项目名}\       # android-home / staging 等
```

## 使用注意事项

**首次运行 / 权限**

- 首次运行时脚本自动检测 `C:\APKTools`：目录不存在或无写权限时会弹出 **UAC 授权框**，点击「是」即自动创建目录并授予当前用户写权限（一次性授权，之后普通权限即可使用）。若取消授权，可右键「以管理员身份运行」手动执行一次，或在 `config.json` 的 `paths.globalToolsRoot` 改用无需提权的路径（如 `D:\APKTools`）。
- 以管理员运行时，脚本会自动启用系统长路径支持（`LongPathsEnabled=1`），**该设置需重启系统后完全生效**；非管理员运行则只提示手动开启命令。
- 所有环境变量（PATH / JAVA_HOME / ANDROID_SDK_ROOT / GRADLE_USER_HOME）仅注入当前进程，**不修改系统/用户环境变量**。

**构建相关**

- 首次使用或切换 `GRADLE_USER_HOME` 后，首次构建会重新下载 Gradle 发行版与全部依赖，耗时明显长于平时（约 10-20 分钟），属正常现象。
- 建议物理内存 ≥ 8GB：脚本强制 Gradle 堆 4G，内存不足时构建前会给出醒目警告。
- Android SDK 许可证默认需交互确认一次（输入 Y）；在 `config.json` 设 `android.acceptLicenses: true` 可跳过。
- 包管理器按锁文件自动选择：`yarn.lock` → yarn，`pnpm-lock.yaml` → pnpm，否则 npm。

**签名密钥（重要）**

- 签名材料位于 `{项目}\.signing\`（keystore + 明文密码文件），**务必离线备份**——丢失后无法以同一身份更新已发布的应用。
- 首次构建生成密钥时，alias 与 dname 默认**按当前项目自动派生**（包名末段→alias、应用名→`CN=`），不同项目互不共用签名身份；也可把自有 keystore 按 `*-upload.jks` 命名放入 `.signing\`，脚本检测到即复用、不会重新生成。
- 脚本已自动把 `.signing/` 写入项目 `.gitignore`，请勿手动移除该条目。
- 可通过环境变量 `BILITOGETHER_SIGNING_PASSWORD` 自定义密钥密码（仅在首次生成 keystore 时生效）。

**原生 Android 项目**

- 无需 `package.json`/`node_modules`，脚本会自动跳过 Node.js 安装与依赖检查。
- 应用模块名不是 `app` 的多模块项目也可以构建：APK 定位会扫描所有模块的 `build\outputs\apk\release`，取最新 APK 签名输出。

**Flutter 项目**

- **无需预装 Git**：Flutter 工具链运行时硬性依赖 `git`（`flutter.bat` 启动时检查），系统 PATH 没有 git 时脚本自动下载便携 MinGit（官方最小化便携版，约 40MB）注入会话，全程无感。
- 优先使用系统已有的 Flutter SDK（PATH / `FLUTTER_ROOT`）；检测不到时自动从国内镜像下载 stable 官方 zip 解压到 `C:\APKTools\flutter\{version}`（约 1GB，zip 缓存在 `.cache\flutter`，重复构建不重复下载）。
- 首次 `flutter build apk` 会下载 Dart SDK 与引擎产物（经 `storage.flutter-io.cn` 镜像），耗时较长属正常。
- **需要符号链接（symlink）支持**：Flutter Windows 插件构建的硬性要求。脚本构建前自动检测，失败时管理员运行会自动开启「开发者模式」（立即生效无需重启）；非管理员则给出开启指引（设置 → 系统 → 开发者选项）。
- `android\` 目录缺少 `gradlew` 也没关系：脚本会先从 Flutter SDK 自带模板补齐 Gradle wrapper（项目已有文件不覆盖），以便 Gradle 发行版走国内镜像下载；若模板缺失则交由 `flutter build` 自动注入。
- pubspec 中的 **git 依赖**（`git: url: https://github.com/...`）经 GitHub 镜像拉取，采用**逐仓库通道选择**：全局默认走探测可用的镜像（gitclone.com 优先），再对项目里每个 git 依赖逐一 `ls-remote` 验证——个别小众仓库在镜像上可能 502/未收录，失败的仓库自动改走兜底镜像或直连（利用 git `insteadOf` 最长前缀匹配规则注入精确重写），全程会话级 `GIT_CONFIG_*` 注入，**不修改你的 `.gitconfig`**；并注入低水位超时（传输停滞 60 秒即中止），避免镜像挂起导致无限等待。可在 `config.json` 的 `git.mirrorInsteadOf` 显式指定全局镜像，或调整 `git.mirrorCandidates` 候选列表。
- **dev git 依赖自动转 hosted**：`dev_dependencies` 中的 git 依赖（如 `jnigen` 这类巨型 monorepo 子包）不参与构建产物，但 `pub get` 仍会全量 mirror clone（大仓库经免费镜像可能数十分钟）。脚本会检测其在 pub 镜像上的同名 hosted 包，存在时自动写入官方 `pubspec_overrides.yaml` 覆盖为 hosted（**不修改原 `pubspec.yaml`**），跳过 git clone。
- Flutter 模板 release 构建默认带 debug 签名，脚本签名阶段会用正式 keystore 整体替换，无需手动处理。

**Cordova 项目**

- Cordova CLI 通过便携 Node 的 npm 全局安装（隔离在便携 Node 目录内，不污染系统）；npm registry 以会话级 `NPM_CONFIG_REGISTRY` 环境变量注入（默认 `https://registry.npmmirror.com`），优先级高于 `.npmrc`，**不修改你的全局 npm 配置**，构建结束自动恢复。
- 如项目未添加 Android 平台，脚本会自动执行 `cordova platform add android`（不带版本号，Cordova restore 语义自动采用项目 `config.xml` `<engine>` / `package.json` 锁定的版本；也可在 `cordova.androidPlatformVersion` 显式指定）。已存在 `platforms\android` 时**完全不动、绝不升级**，避免新版平台破坏旧插件兼容性。
- 构建前执行 `cordova requirements android` 检测环境：缺少的 SDK Platform / build-tools 按 cordova-android 自身要求经镜像源自动补装并复验（版本以平台要求为准，与全局 `android.targetApiLevel` 无关）。
- JDK 版本按 cordova-android 自动选择（≥12→17、10~11→11、≤9→8，版本来源：`platforms\platforms.json` → `package.json` → `config.xml` engine）；老项目插件链不兼容新工具链时，可在 `cordova.jdkMajorVersion` 强制指定 8 / 11 / 17。
- `platforms\android` 目录层级深，脚本以短路径 `GRADLE_USER_HOME` + 构建前 `LongPathsEnabled` 检测双保险规避 260 字符上限；缓存清理对该目录改用 robocopy 强删（`Remove-Item` 在深路径下会失败）。
- Gradle 管理按平台版本自适应：cordova-android **≤14** 自带 wrapper，脚本只做版本中立的优化（下载地址换国内镜像，**只换 host、保留原版本号**）；cordova-android **≥15** 不再捆绑 gradlew，构建需 PATH 上的 Gradle 引导生成 wrapper，脚本自动经华为云/腾讯云镜像安装便携 Gradle（版本自动对齐平台的 `GRADLE_VERSION`，可用 `gradle.bootstrapVersion` 强制指定），并经官方钩子 `CORDOVA_ANDROID_GRADLE_DISTRIBUTION_URL` 让生成的 wrapper 直接走国内镜像分发地址。Maven 仓库经全局 `init.gradle` 重定向阿里云（不改项目文件）、4G 堆内存两种版本通用。
- 正式版 `cordova build android --release` 产出 unsigned APK，走与其他项目类型相同的 zipalign + apksigner 签名流程输出 `app-release.apk`；调试版 `cordova build android` 自带 debug 签名，直接输出 `app-debug.apk`，两者均在 `release\` 目录。（cordova-android ≥15 未指定时 release 默认改产 AAB，脚本已显式 `--packageType=apk` 锁定 APK 输出。）
- `cordova.buildDebug` 设为 `false` 可跳过 debug 版构建，仅输出 release APK。
- 构建失败时脚本按输出特征给出提示：JDK 与平台不匹配（`Unsupported class file major version`）→ 检查 `cordova.jdkMajorVersion`；插件不兼容（`android.support` / `Cannot find symbol` 等）→ 在 `config.xml` 用 `<engine name="android" spec="旧版本"/>` 锁定旧版平台并删除 `platforms` 目录后重试。

**JDK 版本自适应**（所有项目类型）

构建前按项目依赖自动选择 JDK 主版本。可在 `config.json` 中通过 `jdk.autoDetect`（默认 `true`）开关，设为 `false` 时始终使用 `jdk.requiredMajorVersion`（默认 17）。

| 项目类型 | 判断依据 | 版本映射 |
|---|---|---|
| RN / Expo | package.json 中 `react-native` 版本 | >=0.73 → JDK 17；<=0.72 → JDK 11 |
| Expo（无 RN 声明） | package.json 中 `expo` 版本 | >=48 → JDK 17；<48 → JDK 11 |
| Flutter / 原生 Android | build.gradle 中 AGP 版本 | >=8 → JDK 17；7.x → JDK 11；<=6 → JDK 8 |
| Cordova | cordova-android 版本（专属检测） | >=12 → JDK 17；10~11 → JDK 11；<=9 → JDK 8 |

**SDK 需求补装**（所有项目类型）

构建前按项目 `android/build.gradle` 声明的 `compileSdkVersion` / `buildToolsVersion` / `ndkVersion` 检测：
- **Platform / build-tools 缺失** → 经镜像源自动补装（包小，免确认；`requirements.installSdk=true` 控制）
- **NDK 缺失** → 按 `requirements.installNdk` 策略处理：`"ask"`（默认，Y/n 询问）、`"always"`（直接装）、`"never"`（跳过并警告）；NDK 约 1-2GB，建议通过镜像预装避免构建时从 Google 直连下载极度缓慢
- 全部组件已就绪时零网络请求直接通过

**构建失败特征提示**（所有项目类型）

Gradle / Flutter 构建失败时，按输出特征自动诊断并给出中文修复建议：JDK 不匹配 → 调整版本；NDK 缺失 → 补装或配置；SDK 路径错误 → 检查环境变量；许可证未接受 → sdkmanager --licenses；Kotlin 版本不兼容 → 检查 ext 声明；CMake 缺失 → 补装 NDK 组件。

**项目目录变动**

- 项目目录被移动/重命名后，npm workspaces 的 junction 仍指向旧绝对路径。脚本每次构建前会自动检测并重建 workspace 链接、清理悬空链接，无需手动处理；但养成"换目录后先跑一次构建（或重装依赖）"的习惯更稳妥。
- 项目路径本身也请保持短小（如 `D:\BRC\BRC`），路径越深越容易触发各类 260 字符问题。

## 常见问题

**`ninja: error: Stat(...): Filename longer than 260 characters`**
transforms 缓存内 prefab 头文件路径超过 Win32 上限。脚本已用短路径 `GRADLE_USER_HOME`（`C:\APKTools\g\...`）规避，并会在构建前自动清理引用旧路径的 `.cxx` CMake 缓存。若仍出现，检查 `gradleUserHome` 是否被自定义改长，或项目自身路径是否过深。

**构建卡在 `Evaluating settings` 不动**
react-native-gradle-plugin 在 JDK 版本不符时会从 `api.foojay.io` 自动下载 JDK（国内基本卡死）。脚本固定使用便携 JDK 17 并禁用 toolchain 自动下载，正常不会触发；若手动跑 `gradlew` 遇到此问题，请改用本脚本构建。

**`immutable workspace ... have been modified`**
Gradle transforms 缓存损坏（上次构建被强杀/杀软扫描所致）。脚本构建前会预检清除残缺条目，构建中检测到该错误也会自动定位删除并重试一次，一般无需干预；反复出现可执行菜单 `[2] 清理缓存`。

**`node_modules` 里 workspace 包指向旧项目路径**
目录重命名/复制的残留。构建前预检会自动重建指向当前项目的链接并输出日志；看到 `已重建链接` 字样属正常修复过程。

**Flutter 构建 `flutter pub get` 失败（退出码 69，日志含 `unable to read tree`/`Git error`）**
pub 的 git 依赖缓存（`%LOCALAPPDATA%\Pub\Cache\git`）损坏：早前 clone 被网络中断留下残缺对象库，pub 每次复用该坏缓存导致必败——注意这与 pub 镜像连通性无关。脚本检测到该特征会自动清除缓存并重试一次；重试仍失败时检查 git 依赖仓库（GitHub 及镜像代理）连通性，或手动删除上述 `git` 缓存目录后重试。

**Flutter 编译报大量"找不到符号"，且删除 pub 缓存重克隆后原样复现（缺失类清单完全不变）**
这不是缓存损坏，而是 Windows MAX_PATH（260 字符）+ git 未开 `core.longpaths`：pub 缓存路径较深，插件中超过 260 字符的 `.java` 在 checkout 时被 git 静默跳过——引用方文件（≤259 字符）在、定义方文件（≥261 字符）丢，javac 于是报"找不到符号"；每次重克隆跳过的是同一批文件，所以删缓存无效（flutter_inappwebview 等深包名插件最易中招）。脚本已会话级注入 `core.longpaths=true`（GIT_CONFIG_* 环境变量，**不改你的 `.gitconfig`**），重跑构建即可检出完整源码。手动使用 git 如遇同类问题，可执行 `git config --global core.longpaths true`（另需系统开启长路径：注册表 `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled=1`）。

**构建成功但想保留更多历史 APK**
`release\` 目录下同名 APK 会自动追加时间戳后缀，不会被覆盖。

## 运行环境要求

- Windows 10/11，Windows PowerShell 5.1+ 或 PowerShell 7+
- 首次安装依赖需要可访问镜像站的网络（构建全程无需 GitHub 直连；便携 MinGit 默认走 gh-proxy 镜像，直连仅作兜底）
- 建议 8GB+ 物理内存、10GB+ 可用磁盘（SDK/Gradle 缓存占用较大）

## 文件说明

| 文件 | 作用 |
|---|---|
| `build.bat` | 入口，调用 `Menu.ps1` 彩色菜单 |
| `Menu.ps1` | 交互菜单与环境状态展示，以子进程调用 `BuildCore.ps1` |
| `BuildCore.ps1` | 动作分发（Build / Clean / SetupEnv），初始化项目路径 |
| `BuildHelper.psm1` | 模块加载器：按固定顺序点源装配 `Modules\` 下的功能域分文件 |
| `Modules\` | 全部功能实现，按功能域拆分：`00-Config` 配置默认值 / `01-Logging` 日志 / `02-Paths` 路径工具 / `03-ToolsRoot` 工具目录与 UAC 权限自愈 / `04-Network` 下载解压 / `05-Resolvers` 版本解析 / `06-Installers` 便携安装器 / `07-ProjectDetect` 项目检测 / `08-GitMirror` Git 镜像 / `09-NodeModules` 依赖安装修复 / `10-Gradle` Gradle 构建 / `11-Flutter` Flutter 构建 / `12-Signing` 签名输出 / `13-Build` 构建主流程 / `14-YamlLite` 缩进感知的 YAML 子集解析器（pubspec.yaml / pubspec.lock，替换正则抠段，支持注释/任意缩进/引号标量） / `15-Cordova` Cordova 构建（CLI 便携安装、npm 会话级镜像、JDK 8/11/17 自适应、平台自愈不升级、cordova requirements 驱动 SDK 补装、debug/release 双版本输出） / `16-Requirements` SDK 需求解析与补装（按项目 build.gradle 声明检测缺失 SDK Platform/build-tools 自动补装、NDK 询问后补装、JDK 按 RN/AGP 版本自适应、构建失败通用特征提示） |
| `config.example.json` | 配置模板，复制为 `config.json` 后生效 |
## 注意事项
- 建议首次运行时使用管理员权限运行，以便于启用长路径支持。
- 如果你的项目是Monorepo，请将`mobileSubPath`设置为你的项目目录，例如`apps/mobile`，要选中有android目录的子目录。
- 请别在开梯子的时候跑脚本