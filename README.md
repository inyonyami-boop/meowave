# meowave / 喵降

《喵降》的 UrhoX Lua 源码工程交接仓库。游戏正式入口为 `scripts/main.lua`，单机、横屏。

## 文件内容

- `scripts/`：游戏源码、第 1—10 关配置及原资源 `.meta`。
- `assets/`：运行图片、音频、文案，以及保留的美术制作原稿；核验拼图与测试截图不在交接范围内。
- `project_config/resources.json`：原项目资源分组和预下载规则。
- `project_config/settings.json`：不含账号身份的原构建及单机设置。
- `docs/`：术语表与关卡教程设计资料。
- `SHA256SUMS`：交接文件的 SHA-256 校验清单。

未包含原项目 `.project/`、厂商/应用/项目身份、测试二维码、凭据、真实玩家存档、运行日志、构建缓存、测试截图或平台内部开发配置。UrhoX 内置引擎、字体与 `urhox-libs` 由目标开发环境提供，不在此仓库重复分发。

## 获取与恢复工程

1. 通过仓库的 **Code → Download ZIP** 下载并解压；也可以 `git clone` 此仓库。下载 ZIP 时，先进入解压后的仓库根目录，确保它直接包含 `scripts/` 和 `assets/`。
2. 使用队长自己的 TapTap 账号和报名厂商，在支持 UrhoX Lua 的 TapTap 制造/Code 开发环境中准备目标项目。仓库本身不会继承或转移原应用归属。
3. 将 `scripts/`、`assets/` 放到目标项目根目录，不额外嵌套一层目录，也不要重新生成资源 `.meta` 的 UUID。
4. 目标项目应使用：脚本目录 `scripts`、单机入口 `main.lua`、横屏。请使用目标平台提供的官方初始化/构建方式生成自己的 `.project/`，不要复制原厂商绑定。
5. `project_config/` 是可移交的配置副本，不会被运行时自动当作 `.project/` 加载。确认目标项目资源根仍为 `assets`、`scripts`，然后在目标项目的受支持配置界面/流程中应用相同的资源规则和构建设置；保留目标项目新生成的身份、关联与认证信息。
6. 在目标环境运行 Lua LSP 检查，再使用官方构建工具构建 `main.lua`。首次初始化单机配置为 `enabled=false`。
7. 预览并验收后，按照活动官方要求绑定 GameJam、上传并投稿。目标平台是否支持从 ZIP/Git 导入工程、以及队长账号下的具体操作，需由该平台界面确认。

## 校验

在仓库根目录，Linux/Git Bash 可以运行：

```sh
sha256sum -c SHA256SUMS
```

校验清单覆盖交接内容，不包括 `.git/` 以及清单自身。

## 已知边界

- **本仓库是源码工程，不是 APK、Windows EXE 或已经被投稿后台认可的 H5 上传包。** Download ZIP 只提供工程归档，不保证能直接作为包体上传。
- 现有源码依赖 UrhoX 内置 UI、ImageCache、PlatformUtils 和内置 MiSans 字体，不能仅用标准 Lua 解释器运行。
- 打包前原项目官方 `main.lua` 构建成功；当前 LSP 为 0 Error、1 Warning、26 Hint，其中 Warning 为 `Global/VerticalView.lua` 的既有 number/integer 类型提示。本次交接没有修改游戏源码，也没有在队长账号下构建或投稿。
- 原生平台 Esc 自动退出拦截仍有已知限制；不要将源码交接视为此问题已修复。
- 仓库未附加新的许可协议或赛事素材授权声明；下载/发布前请由项目拥有者确认素材授权与参赛资格。
